defmodule Omni.Agent.Server do
  @moduledoc false

  # Lifecycle: turn > step
  #
  #   prompt/3 ──► TURN START
  #   │
  #   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete ──► :step event
  #   │   └─ tool_use? ──► handle_tool_decision_phase ──► spawn_executor
  #   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete ──► :step event
  #   │   └─ tool_use? ──► ...repeat...
  #   └─ evaluate_head ──► assistant (no tools) ──► finalize_turn ──► handle_turn
  #       ├─ {:continue, prompt} ──► :continue event ──► new step(s)
  #       └─ {:stop, state} ──► complete_turn ──► :stop event ──► TURN END

  use GenServer

  alias Omni.{Context, Message, Model, Response, Tool, Usage}
  alias Omni.Agent.{Snapshot, State, Tree}
  alias Omni.Content.{Text, Thinking, ToolResult, ToolUse}

  defstruct [
    # Public state (passed to callbacks)
    :state,

    # Configuration (set at init, stable across turns)
    :module,
    :store,
    :tool_timeout,
    store_opts: [],

    # Subscribers: pids that receive agent events, monitored for DOWN cleanup.
    subscribers: MapSet.new(),
    monitors: %{},

    # Turn lifecycle (set when a prompt starts, cleared by reset_turn)
    # turn_start_node_id: id of the user node that opened the current turn;
    #   used to derive the per-turn message slice for response events and to
    #   rewind the active path on cancel/error.
    # prompt_opts: merged opts for the current turn (state.opts + call-site opts)
    # next_prompt: staged {content, opts} tuple, set when prompt/3 is called
    #   while running/paused
    # partial_message: content blocks streamed so far for the in-flight
    #   assistant message; nil between steps and when not streaming
    turn_start_node_id: nil,
    prompt_opts: [],
    next_prompt: nil,
    last_response: nil,
    partial_message: nil,

    # Process tracking
    step_task: nil,
    executor_task: nil,

    # Tool decision phase (set when tool decisions begin, cleared by reset_turn)
    tool_map: nil,
    approved_uses: [],
    remaining_uses: [],
    rejected_results: [],
    provided_results: [],
    paused_info: nil
  ]

  @settable_fields [:model, :system, :tools, :opts, :meta]
  @rejected_init_opts [:listener, :context, :messages]

  def start_link(init_arg, gs_opts) do
    # Capture $callers so the chain reaches back to whoever started the agent.
    # GenServer doesn't propagate $callers like Task does, so without this,
    # process-ownership registries (Req.Test, Mox) in spawned step processes
    # can't trace back to the originating process.
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, {callers, init_arg}, gs_opts)
  end

  # -- Init --

  @impl GenServer
  def init({callers, {module, opts}}) do
    Process.put(:"$callers", callers)
    Process.flag(:trap_exit, true)

    with :ok <- validate_init_opts(opts),
         {:ok, mode} <- resolve_mode(opts),
         {:ok, hydrated} <- hydrate(mode, opts),
         {:ok, model} <- resolve_model(opts[:model], hydrated[:model]),
         {:ok, private} <- call_init(module, opts) do
      state = build_state(hydrated, opts, model, private)

      server = %__MODULE__{
        state: state,
        module: module,
        store: opts[:store],
        store_opts: store_opts(opts),
        tool_timeout: Keyword.get(opts, :tool_timeout, 5_000)
      }

      :ok = save_initial_state(server, mode)

      {:ok, server}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # Phase-1 rejection list first (fail loudly on legacy opts), then
  # validate the :store/:new/:load/:id interactions.
  defp validate_init_opts(opts) do
    case Enum.find(@rejected_init_opts, &Keyword.has_key?(opts, &1)) do
      nil -> validate_store_opts(opts)
      key -> {:error, {:invalid_opt, key}}
    end
  end

  defp validate_store_opts(opts) do
    store? = Keyword.has_key?(opts, :store)
    new? = Keyword.has_key?(opts, :new)
    load? = Keyword.has_key?(opts, :load)
    id? = Keyword.has_key?(opts, :id)

    cond do
      new? and load? ->
        {:error, :conflicting_opts}

      (new? or load?) and not store? ->
        {:error, :store_required}

      id? and (store? or new? or load?) ->
        # :id is ephemeral-only; persistent agents use :new / :load.
        {:error, {:invalid_opts, [:id]}}

      load? ->
        case for k <- [:tree, :meta], Keyword.has_key?(opts, k), do: k do
          [] -> :ok
          fields -> {:error, {:invalid_load_opts, fields}}
        end

      true ->
        :ok
    end
  end

  # Mode determines how state is sourced:
  #   :ephemeral   — from opts only; no persistence
  #   {:new, id}   — persistent, fresh; id from :new, or generated
  #   {:load, id}  — persistent, hydrated from the store
  defp resolve_mode(opts) do
    store = Keyword.get(opts, :store)
    new = Keyword.get(opts, :new)
    load = Keyword.get(opts, :load)

    cond do
      is_binary(load) ->
        {:ok, {:load, load}}

      is_binary(new) ->
        {:ok, {:new, new}}

      not is_nil(store) ->
        {:ok, {:new, Omni.Agent.generate_id()}}

      true ->
        {:ok, :ephemeral}
    end
  end

  # Returns a map of persisted fields for use by build_state/4 and
  # resolve_model/2. Empty map for ephemeral mode; probe-for-collision
  # semantics for new-mode; loads from the store for load-mode.
  defp hydrate(:ephemeral, _opts), do: {:ok, %{id: nil}}

  defp hydrate({:new, id}, opts) do
    store = Keyword.fetch!(opts, :store)

    case store.load(id, store_opts(opts)) do
      {:error, :not_found} -> {:ok, %{id: id}}
      {:ok, _persisted} -> {:error, :already_exists}
    end
  end

  defp hydrate({:load, id}, opts) do
    store = Keyword.fetch!(opts, :store)

    case store.load(id, store_opts(opts)) do
      {:ok, persisted} -> {:ok, Map.put(persisted, :id, id)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Apply the load-time field category policy:
  #   - runtime-only (:tools, callback module, :tool_timeout, :store) — always from opts
  #   - overridable  (:model, :system, :opts) — caller wins when present, else persisted
  #   - owned        (:tree, :meta) — always from persisted (validator rejects caller overrides)
  defp build_state(hydrated, opts, model, private) do
    %State{
      id: hydrated[:id] || opts[:id],
      model: model,
      system: opts[:system] || hydrated[:system],
      tools: opts[:tools] || [],
      tree: hydrated[:tree] || opts[:tree] || %Tree{},
      opts: Keyword.get(opts, :opts) || hydrated[:opts] || [],
      meta: hydrated[:meta] || opts[:meta] || %{},
      private: private
    }
  end

  # Lenient model resolution: caller's opt wins, persisted ref is the
  # fallback, and if both fail we report :model_not_found.
  defp resolve_model(caller_model, persisted_ref) do
    case resolve_model_ref(caller_model) do
      {:ok, model} ->
        {:ok, model}

      {:error, _} = err ->
        case resolve_model_ref(persisted_ref) do
          {:ok, model} -> {:ok, model}
          {:error, _} -> fallback_model_error(caller_model, persisted_ref, err)
        end
    end
  end

  defp resolve_model_ref({provider_id, model_id}), do: Model.get(provider_id, model_id)
  defp resolve_model_ref(%Model{} = model), do: {:ok, model}
  defp resolve_model_ref(nil), do: {:error, :missing_model}

  defp fallback_model_error(nil, nil, err), do: err
  defp fallback_model_error(_caller, _persisted, _err), do: {:error, :model_not_found}

  # Persist the resolved state on first init for persistent modes.
  # This ensures a load-with-overrides writes the caller's values back
  # immediately rather than waiting for the next set_state. Errors are
  # swallowed silently — no subscribers exist yet to receive a :store
  # event. SD4 refines this with proper error surfacing.
  defp save_initial_state(%__MODULE__{store: nil}, _mode), do: :ok
  defp save_initial_state(_server, :ephemeral), do: :ok

  defp save_initial_state(%__MODULE__{store: store, store_opts: sopts, state: state}, _mode) do
    state_data = %{
      tree: state.tree,
      model: Model.to_ref(state.model),
      system: state.system,
      opts: state.opts,
      meta: state.meta
    }

    _ = store.save_state(state.id, state_data, sopts)
    _ = if Tree.size(state.tree) > 0, do: store.save_tree(state.id, state.tree, sopts)
    :ok
  end

  # Strip framework opts so adapters see only adapter-level options
  # (e.g. :base_path for FileSystem). The behaviour isn't strict about
  # this, but it keeps the contract clean — :store/:new/:load/:id are
  # mode selectors, state-field names are handled by the server, and
  # the inference :opts keyword is not adapter-relevant.
  defp store_opts(opts) do
    Keyword.drop(opts, [
      :store,
      :new,
      :load,
      :id,
      :model,
      :system,
      :tools,
      :tree,
      :meta,
      :opts,
      :tool_timeout
    ])
  end

  # -- Calls --

  @impl GenServer
  def handle_call(
        {:prompt, content, opts},
        _from,
        %__MODULE__{state: %{status: :idle}} = server
      ) do
    server = start_turn(content, opts, server)
    {:reply, :ok, server}
  end

  def handle_call(
        {:prompt, _content, _opts} = call,
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:running, :paused] do
    {:prompt, content, opts} = call
    {:reply, :ok, %{server | next_prompt: {content, opts}}}
  end

  def handle_call({:resume, decision}, _from, %__MODULE__{state: %{status: :paused}} = server) do
    {_reason, tool_use} = server.paused_info

    server = %{
      server
      | state: %{server.state | status: :running},
        paused_info: nil
    }

    server =
      case decision do
        :execute ->
          %{server | approved_uses: [tool_use | server.approved_uses]}

        {:reject, reason} ->
          result =
            ToolResult.new(
              tool_use_id: tool_use.id,
              name: tool_use.name,
              content: "Tool rejected: #{inspect(reason)}",
              is_error: true
            )

          %{server | rejected_results: server.rejected_results ++ [result]}

        {:result, result} ->
          %{server | provided_results: server.provided_results ++ [result]}
      end

    server = process_next_tool_decision(server)
    {:reply, :ok, server}
  end

  def handle_call({:resume, _decision}, _from, server) do
    {:reply, {:error, :not_paused}, server}
  end

  def handle_call(:cancel, _from, %__MODULE__{state: %{status: status}} = server)
      when status in [:running, :paused] do
    server = do_cancel(server)
    {:reply, :ok, server}
  end

  def handle_call(:cancel, _from, server) do
    {:reply, {:error, :idle}, server}
  end

  # -- Subscribe / Unsubscribe --

  def handle_call({:subscribe, pid}, _from, server) do
    if MapSet.member?(server.subscribers, pid) do
      {:reply, {:ok, build_snapshot(server)}, server}
    else
      ref = Process.monitor(pid)
      snapshot = build_snapshot(server)

      server = %{
        server
        | subscribers: MapSet.put(server.subscribers, pid),
          monitors: Map.put(server.monitors, ref, pid)
      }

      {:reply, {:ok, snapshot}, server}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, server) do
    case find_monitor_ref(server.monitors, pid) do
      nil ->
        {:reply, :ok, server}

      ref ->
        Process.demonitor(ref, [:flush])

        server = %{
          server
          | subscribers: MapSet.delete(server.subscribers, pid),
            monitors: Map.delete(server.monitors, ref)
        }

        {:reply, :ok, server}
    end
  end

  # -- set_state/2 --

  def handle_call(
        {:set_state, opts},
        _from,
        %__MODULE__{state: %{status: :idle}} = server
      ) do
    case apply_set_state(server.state, opts) do
      {:ok, new_state} ->
        server = %{server | state: new_state}
        maybe_save_state(server, new_state)
        {:reply, :ok, server}

      {:error, _} = error ->
        {:reply, error, server}
    end
  end

  # -- set_state/3 --

  def handle_call(
        {:set_state, field, value_or_fun},
        _from,
        %__MODULE__{state: %{status: :idle}} = server
      )
      when field in @settable_fields do
    new_value =
      if is_function(value_or_fun, 1),
        do: value_or_fun.(Map.get(server.state, field)),
        else: value_or_fun

    case maybe_resolve_field(field, new_value) do
      {:ok, resolved} ->
        new_state = Map.put(server.state, field, resolved)
        server = %{server | state: new_state}
        maybe_save_state(server, new_state)
        {:reply, :ok, server}

      {:error, _} = error ->
        {:reply, error, server}
    end
  end

  def handle_call(
        {:set_state, field, _value_or_fun},
        _from,
        %__MODULE__{state: %{status: :idle}} = server
      ) do
    {:reply, {:error, {:invalid_field, field}}, server}
  end

  # Catch-all for mutating ops while running or paused
  def handle_call({:set_state, _}, _from, server), do: {:reply, {:error, :running}, server}
  def handle_call({:set_state, _, _}, _from, server), do: {:reply, {:error, :running}, server}

  def handle_call(:get_state, _from, server), do: {:reply, server.state, server}

  def handle_call({:get_state, key}, _from, server),
    do: {:reply, Map.get(server.state, key), server}

  # -- Navigate --

  def handle_call(
        {:navigate, node_id},
        _from,
        %__MODULE__{state: %{status: :idle}} = server
      ) do
    case Tree.navigate(server.state.tree, node_id) do
      {:ok, tree} ->
        server = %{server | state: %{server.state | tree: tree}}
        notify(server, :tree, tree)
        {:reply, :ok, server}

      {:error, :not_found} = error ->
        {:reply, error, server}
    end
  end

  def handle_call({:navigate, _}, _from, server), do: {:reply, {:error, :streaming}, server}

  # -- Regenerate --

  def handle_call(:regenerate, _from, %__MODULE__{state: %{status: :idle}} = server) do
    case do_regenerate(server) do
      {:ok, server} -> {:reply, :ok, server}
      {:error, _} = error -> {:reply, error, server}
    end
  end

  def handle_call(:regenerate, _from, server), do: {:reply, {:error, :streaming}, server}

  # -- Info (step messages) --

  @impl GenServer
  def handle_info({ref, {:event, type, event_map}}, %{step_task: {_, ref}} = server) do
    server = accumulate_partial(server, type, event_map)
    notify(server, type, event_map)
    {:noreply, server}
  end

  def handle_info({ref, {:complete, %Response{} = response}}, %{step_task: {_, ref}} = server) do
    server = handle_step_complete(response, server)
    {:noreply, server}
  end

  def handle_info({ref, {:error, reason}}, %{step_task: {_, ref}} = server) do
    server = %{server | step_task: nil}

    case call_handle_error(server.module, reason, server.state) do
      {:retry, new_state} ->
        notify(server, :retry, reason)
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = %{server | state: new_state} |> rewind_turn() |> reset_turn()
        notify(server, :error, reason)
        {:noreply, server}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{step_task: {pid, _}} = server)
      when reason not in [:normal, :killed] do
    error = {:step_crashed, reason}
    server = %{server | step_task: nil}

    case call_handle_error(server.module, error, server.state) do
      {:retry, new_state} ->
        notify(server, :retry, error)
        {:noreply, spawn_step(%{server | state: new_state})}

      {:stop, new_state} ->
        server = %{server | state: new_state} |> rewind_turn() |> reset_turn()
        notify(server, :error, error)
        {:noreply, server}
    end
  end

  # -- Info (executor messages) --

  def handle_info({ref, {:tools_executed, results}}, %{executor_task: {_, ref}} = server) do
    server = handle_tools_executed(results, server)
    {:noreply, server}
  end

  def handle_info({:EXIT, pid, reason}, %{executor_task: {pid, _}} = server)
      when reason not in [:normal, :killed] do
    error = {:executor_crashed, reason}
    server = %{server | executor_task: nil}

    case call_handle_error(server.module, error, server.state) do
      {:retry, new_state} ->
        notify(server, :retry, error)
        approved = Enum.reverse(server.approved_uses)
        {:noreply, spawn_executor(approved, %{server | state: new_state})}

      {:stop, new_state} ->
        server = %{server | state: new_state} |> rewind_turn() |> reset_turn()
        notify(server, :error, error)
        {:noreply, server}
    end
  end

  # -- Info (subscriber DOWN) --

  def handle_info({:DOWN, ref, :process, _pid, _reason}, server) do
    case Map.pop(server.monitors, ref) do
      {nil, _} ->
        {:noreply, server}

      {pid, monitors} ->
        {:noreply,
         %{server | subscribers: MapSet.delete(server.subscribers, pid), monitors: monitors}}
    end
  end

  def handle_info(_msg, server) do
    {:noreply, server}
  end

  # -- Terminate --

  @impl GenServer
  def terminate(reason, server) do
    flush_on_terminate(server)
    call_terminate(server.module, reason, server.state)
  end

  # Best-effort final save on graceful shutdown. Rare in practice —
  # write-through covers the normal flow — but guards against any
  # future op that stages state without an immediate save.
  defp flush_on_terminate(%__MODULE__{store: nil}), do: :ok

  defp flush_on_terminate(%__MODULE__{} = server) do
    maybe_save_state(server, server.state)
  catch
    kind, reason ->
      require Logger
      Logger.warning("Omni.Agent terminate flush failed: #{inspect({kind, reason})}")
      :ok
  end

  # -- Regenerate (idle-only, dispatched from handle_call) --

  defp do_regenerate(server) do
    tree = server.state.tree

    case Tree.head(tree) do
      nil ->
        {:error, :invalid_head}

      head_id ->
        head = Tree.get_node(tree, head_id)

        case head.message.role do
          :user ->
            start_regeneration(head_id, server)

          :assistant ->
            case head.parent_id do
              nil ->
                {:error, :invalid_head}

              parent_id ->
                parent = Tree.get_node(tree, parent_id)

                if parent && parent.message.role == :user do
                  {:ok, tree} = Tree.navigate(tree, parent_id)
                  server = %{server | state: %{server.state | tree: tree}}
                  notify(server, :tree, tree)
                  start_regeneration(parent_id, server)
                else
                  {:error, :invalid_head}
                end
            end

          _ ->
            {:error, :invalid_head}
        end
    end
  end

  defp start_regeneration(user_node_id, server) do
    prompt_opts = server.state.opts

    server = %{
      server
      | state: %{server.state | status: :running, step: 0},
        turn_start_node_id: user_node_id,
        prompt_opts: prompt_opts
    }

    {:ok, evaluate_head(server)}
  end

  # -- Turn start --

  defp start_turn(content, opts, server) do
    user_message = Message.new(role: :user, content: content)
    prompt_opts = Keyword.merge(server.state.opts, opts)

    {node_id, tree} = Tree.push_node(server.state.tree, user_message)

    server = %{
      server
      | state: %{server.state | status: :running, step: 0, tree: tree},
        turn_start_node_id: node_id,
        prompt_opts: prompt_opts
    }

    notify_push(server, node_id)
    maybe_save_tree(server, node_id)
    evaluate_head(server)
  end

  # -- evaluate_head: unified state machine --

  defp evaluate_head(server) do
    if max_steps_reached?(server) do
      finalize_turn(server.last_response, server)
    else
      last_message = Tree.get_node(server.state.tree, Tree.head(server.state.tree)).message

      cond do
        last_message.role == :user ->
          spawn_step(server)

        has_tool_uses?(last_message) ->
          tool_uses = extract_tool_uses(last_message.content)
          handle_tool_decision_phase(tool_uses, server)

        true ->
          finalize_turn(server.last_response, server)
      end
    end
  end

  defp has_tool_uses?(message) do
    Enum.any?(message.content, &match?(%ToolUse{}, &1))
  end

  # -- Step execution --

  defp spawn_step(server) do
    full_context = build_context(server)

    opts = Keyword.merge(server.prompt_opts, max_steps: 1)
    ref = make_ref()

    {:ok, pid} = Omni.Agent.Step.start_link(self(), ref, server.state.model, full_context, opts)

    step = server.state.step + 1
    %{server | step_task: {pid, ref}, state: %{server.state | step: step}}
  end

  defp build_context(server) do
    %Context{
      system: server.state.system,
      tools: server.state.tools,
      messages: Tree.messages(server.state.tree)
    }
  end

  # -- Step completion --

  defp handle_step_complete(response, server) do
    {node_id, tree} = Tree.push_node(server.state.tree, response.message, response.usage)

    server = %{
      server
      | state: %{server.state | tree: tree},
        step_task: nil,
        last_response: response,
        partial_message: nil
    }

    notify_push(server, node_id)
    maybe_save_tree(server, node_id)
    notify(server, :step, response)
    evaluate_head(server)
  end

  # -- Tool decision phase --

  defp handle_tool_decision_phase(tool_uses, server) do
    tool_map = build_tool_map(server.state.tools)

    %{server | tool_map: tool_map, remaining_uses: tool_uses, approved_uses: []}
    |> process_next_tool_decision()
  end

  defp process_next_tool_decision(%{remaining_uses: []} = server) do
    approved = Enum.reverse(server.approved_uses)

    has_unhandled =
      Enum.any?(approved, fn tool_use ->
        case Map.get(server.tool_map, tool_use.name) do
          %Tool{handler: handler} when not is_nil(handler) -> false
          _ -> true
        end
      end)

    cond do
      has_unhandled ->
        finalize_turn(server.last_response, server)

      approved == [] ->
        handle_tools_executed([], server)

      true ->
        spawn_executor(approved, server)
    end
  end

  defp process_next_tool_decision(%{remaining_uses: [tool_use | rest]} = server) do
    server = %{server | remaining_uses: rest}

    case call_handle_tool_use(server.module, tool_use, server.state) do
      {:execute, new_state} ->
        %{server | state: new_state, approved_uses: [tool_use | server.approved_uses]}
        |> process_next_tool_decision()

      {:reject, reason, new_state} ->
        result =
          ToolResult.new(
            tool_use_id: tool_use.id,
            name: tool_use.name,
            content: "Tool rejected: #{inspect(reason)}",
            is_error: true
          )

        %{server | state: new_state, rejected_results: server.rejected_results ++ [result]}
        |> process_next_tool_decision()

      {:result, result, new_state} ->
        %{server | state: new_state, provided_results: server.provided_results ++ [result]}
        |> process_next_tool_decision()

      {:pause, reason, new_state} ->
        %{
          server
          | state: %{new_state | status: :paused},
            paused_info: {reason, tool_use}
        }
        |> tap(&notify(&1, :pause, {reason, tool_use}))
    end
  end

  defp spawn_executor(approved_uses, server) do
    ref = make_ref()

    {:ok, pid} =
      Omni.Agent.Executor.start_link(
        self(),
        ref,
        approved_uses,
        server.tool_map,
        server.tool_timeout
      )

    %{server | executor_task: {pid, ref}}
  end

  # -- Tool execution results --

  defp handle_tools_executed(executed_results, server) do
    all_results =
      server.rejected_results ++ Enum.reverse(server.provided_results) ++ executed_results

    server = %{server | executor_task: nil, rejected_results: [], provided_results: []}

    # Call handle_tool_result for each and notify subscribers
    {final_results, server} =
      Enum.map_reduce(all_results, server, fn result, srv ->
        case call_handle_tool_result(srv.module, result, srv.state) do
          {:ok, final_result, new_state} ->
            srv = %{srv | state: new_state}

            notify(srv, :tool_result, final_result)

            {final_result, srv}
        end
      end)

    # Build user message with all tool results, push to tree
    user_message = Message.new(role: :user, content: final_results)
    {node_id, tree} = Tree.push_node(server.state.tree, user_message)
    server = %{server | state: %{server.state | tree: tree}}
    notify_push(server, node_id)
    maybe_save_tree(server, node_id)

    evaluate_head(server)
  end

  # -- Finalize turn --

  defp finalize_turn(response, server) do
    case call_handle_turn(server.module, response, server.state) do
      {:continue, prompt, new_state} ->
        server = %{server | state: new_state}

        cond do
          max_steps_reached?(server) ->
            complete_turn(response, server)

          server.next_prompt != nil ->
            {content, opts} = server.next_prompt
            prompt_opts = Keyword.merge(server.state.opts, opts)
            server = %{server | next_prompt: nil, prompt_opts: prompt_opts}
            continue_turn(content, server)

          true ->
            continue_turn(prompt, server)
        end

      {:stop, new_state} ->
        server = %{server | state: new_state}

        cond do
          server.next_prompt != nil and not max_steps_reached?(server) ->
            {content, opts} = server.next_prompt
            prompt_opts = Keyword.merge(server.state.opts, opts)
            server = %{server | next_prompt: nil, prompt_opts: prompt_opts}
            continue_turn(content, server)

          true ->
            complete_turn(response, server)
        end
    end
  end

  defp continue_turn(prompt, server) do
    response = build_turn_response(server)
    notify(server, :continue, response)

    user_message = Message.new(role: :user, content: prompt)
    {node_id, tree} = Tree.push_node(server.state.tree, user_message)
    server = %{server | state: %{server.state | tree: tree}}
    notify_push(server, node_id)
    maybe_save_tree(server, node_id)

    evaluate_head(server)
  end

  defp complete_turn(_response, server) do
    response = build_turn_response(server)
    server = reset_turn(server)
    notify(server, :stop, response)
    server
  end

  # -- Cancel --

  defp do_cancel(server) do
    kill_task(server.step_task)
    kill_task(server.executor_task)

    response = build_cancel_response(server)
    server = rewind_turn(server)
    server = reset_turn(server)
    notify(server, :cancelled, response)
    server
  end

  # Rewinds the active path to the parent of turn_start_node_id and emits :tree.
  # The turn's nodes stay in the tree as an abandoned branch — navigation can
  # still reach them. Called on cancel and on `:stop` error responses.
  defp rewind_turn(%{turn_start_node_id: nil} = server), do: server

  defp rewind_turn(server) do
    start_node = Tree.get_node(server.state.tree, server.turn_start_node_id)
    parent_id = start_node && start_node.parent_id

    {:ok, tree} = Tree.navigate(server.state.tree, parent_id)
    server = %{server | state: %{server.state | tree: tree}}
    notify(server, :tree, tree)
    server
  end

  defp kill_task(nil), do: :ok
  defp kill_task({pid, _ref}), do: Process.exit(pid, :kill)

  defp find_monitor_ref(monitors, pid) do
    Enum.find_value(monitors, fn {ref, p} -> if p == pid, do: ref end)
  end

  # -- Response builders --

  defp build_turn_response(server) do
    messages = turn_messages(server)
    last_assistant = find_last_assistant(messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: messages,
      output: if(server.last_response, do: server.last_response.output),
      stop_reason: if(server.last_response, do: server.last_response.stop_reason, else: :stop),
      usage: turn_usage(server)
    }
  end

  defp build_cancel_response(server) do
    messages = turn_messages(server)
    last_assistant = find_last_assistant(messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: messages,
      stop_reason: :cancelled,
      usage: turn_usage(server)
    }
  end

  defp find_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end

  # Returns the messages added to the tree during the current turn, in order.
  # Walks the active path and drops nodes prior to turn_start_node_id.
  defp turn_messages(%{turn_start_node_id: nil}), do: []

  defp turn_messages(%{turn_start_node_id: start_id, state: %{tree: tree}}) do
    tree
    |> Enum.drop_while(fn node -> node.id != start_id end)
    |> Enum.map(& &1.message)
  end

  # Sums usage across the per-turn node slice.
  defp turn_usage(%{turn_start_node_id: nil}), do: %Usage{}

  defp turn_usage(%{turn_start_node_id: start_id, state: %{tree: tree}}) do
    tree
    |> Enum.drop_while(fn node -> node.id != start_id end)
    |> Enum.reduce(%Usage{}, fn node, acc ->
      case node.usage do
        nil -> acc
        u -> Usage.add(acc, u)
      end
    end)
  end

  # -- Snapshot --

  defp build_snapshot(server) do
    s = server.state

    %Snapshot{
      id: s.id,
      model: s.model,
      system: s.system,
      tools: s.tools,
      tree: s.tree,
      opts: s.opts,
      meta: s.meta,
      status: s.status,
      step: s.step,
      partial_message: server.partial_message,
      paused: server.paused_info
    }
  end

  # -- Partial message accumulation --

  defp accumulate_partial(server, :text_start, %{index: idx}) do
    put_partial_block(server, idx, %Text{text: ""})
  end

  defp accumulate_partial(server, :text_delta, %{index: idx, delta: d}) do
    update_partial_block(server, idx, fn %Text{text: t} = b -> %{b | text: t <> d} end)
  end

  defp accumulate_partial(server, :text_end, %{index: idx, content: content}) do
    put_partial_block(server, idx, content)
  end

  defp accumulate_partial(server, :thinking_start, %{index: idx}) do
    put_partial_block(server, idx, %Thinking{text: ""})
  end

  defp accumulate_partial(server, :thinking_delta, %{index: idx, delta: d}) do
    update_partial_block(server, idx, fn %Thinking{text: t} = b ->
      %{b | text: (t || "") <> d}
    end)
  end

  defp accumulate_partial(server, :thinking_end, %{index: idx, content: content}) do
    put_partial_block(server, idx, content)
  end

  defp accumulate_partial(server, :tool_use_start, %{index: idx, id: id, name: name}) do
    put_partial_block(server, idx, %ToolUse{id: id, name: name, input: %{}})
  end

  defp accumulate_partial(server, :tool_use_delta, _event_map) do
    # Tool-use input arrives as incrementally-built JSON text that we can't
    # parse reliably until the block ends. The placeholder ToolUse struct
    # from :tool_use_start stays in place until :tool_use_end replaces it.
    server
  end

  defp accumulate_partial(server, :tool_use_end, %{index: idx, content: content}) do
    put_partial_block(server, idx, content)
  end

  defp accumulate_partial(server, _type, _event_map), do: server

  defp put_partial_block(server, idx, block) do
    list = server.partial_message || []
    %{server | partial_message: place_at(list, idx, block)}
  end

  defp update_partial_block(server, idx, fun) do
    case server.partial_message do
      nil -> server
      list -> %{server | partial_message: List.update_at(list, idx, fun)}
    end
  end

  defp place_at(list, idx, block) do
    cond do
      idx < length(list) -> List.replace_at(list, idx, block)
      idx == length(list) -> list ++ [block]
      true -> list ++ List.duplicate(nil, idx - length(list)) ++ [block]
    end
  end

  # -- set_state --

  defp apply_set_state(state, opts) do
    with :ok <- validate_set_state_keys(opts),
         {:ok, state} <- maybe_resolve_model(state, opts) do
      state =
        Enum.reduce(opts, state, fn
          {:model, _}, acc -> acc
          {key, value}, acc -> Map.put(acc, key, value)
        end)

      {:ok, state}
    end
  end

  defp validate_set_state_keys(opts) do
    case Enum.find(opts, fn {key, _} -> key not in @settable_fields end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_key, key}}
    end
  end

  defp maybe_resolve_model(state, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model_ref} ->
        case resolve_model_ref(model_ref) do
          {:ok, model} -> {:ok, %{state | model: model}}
          {:error, _} -> {:error, {:model_not_found, model_ref}}
        end

      :error ->
        {:ok, state}
    end
  end

  defp maybe_resolve_field(:model, value) do
    case resolve_model_ref(value) do
      {:ok, model} -> {:ok, model}
      {:error, _} -> {:error, {:model_not_found, value}}
    end
  end

  defp maybe_resolve_field(_field, value), do: {:ok, value}

  # -- Helpers --

  defp reset_turn(server) do
    %{
      server
      | state: %{server.state | status: :idle, step: 0},
        turn_start_node_id: nil,
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        provided_results: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        tool_map: nil,
        approved_uses: [],
        remaining_uses: [],
        partial_message: nil,
        paused_info: nil
    }
  end

  defp max_steps_reached?(server) do
    max = Keyword.get(server.prompt_opts, :max_steps, :infinity)
    max != :infinity and server.state.step >= max
  end

  defp extract_tool_uses(content) do
    Enum.filter(content, &match?(%ToolUse{}, &1))
  end

  defp build_tool_map(tools) do
    Map.new(tools, fn tool -> {tool.name, tool} end)
  end

  defp notify(server, type, data) do
    msg = {:agent, self(), type, data}
    Enum.each(server.subscribers, &send(&1, msg))
    :ok
  end

  # Emits :message + :node for a node just pushed to the tree. :message is the
  # flat-consumer path; :node carries tree metadata (%{id, parent_id, message,
  # usage}) for tree-aware consumers. Both fire on every push.
  defp notify_push(server, node_id) do
    node = Tree.get_node(server.state.tree, node_id)
    notify(server, :message, node.message)
    notify(server, :node, node)
    :ok
  end

  # -- Persistence (write-through) --

  # Broadcast a write-through failure to subscribers. The live agent
  # continues operating on in-memory state; callers never see the error.
  defp broadcast_store_error(server, op, reason) do
    notify(server, :store, {:error, {op, reason}})
    :ok
  end

  # Incrementally persist a single tree node. No-op when no store is
  # attached. Errors surface as :store events, never propagate.
  defp maybe_save_tree(%__MODULE__{store: nil}, _node_id), do: :ok

  defp maybe_save_tree(%__MODULE__{} = server, node_id) do
    opts = Keyword.put(server.store_opts, :new_node_ids, [node_id])

    case server.store.save_tree(server.state.id, server.state.tree, opts) do
      :ok -> :ok
      {:error, reason} -> broadcast_store_error(server, :save_tree, reason)
    end
  end

  # Persist the serialisable subset of state. Called on set_state and at
  # terminate. No-op when no store is attached.
  defp maybe_save_state(%__MODULE__{store: nil}, _state), do: :ok

  defp maybe_save_state(%__MODULE__{} = server, %State{} = state) do
    state_data = %{
      tree: state.tree,
      model: Model.to_ref(state.model),
      system: state.system,
      opts: state.opts,
      meta: state.meta
    }

    case server.store.save_state(state.id, state_data, server.store_opts) do
      :ok -> :ok
      {:error, reason} -> broadcast_store_error(server, :save_state, reason)
    end
  end

  # -- Callback dispatch --

  defp call_init(nil, _opts), do: {:ok, %{}}
  defp call_init(module, opts), do: module.init(opts)

  defp call_handle_turn(nil, _response, state), do: {:stop, state}
  defp call_handle_turn(module, response, state), do: module.handle_turn(response, state)

  defp call_handle_tool_use(nil, _tool_use, state), do: {:execute, state}

  defp call_handle_tool_use(module, tool_use, state),
    do: module.handle_tool_use(tool_use, state)

  defp call_handle_tool_result(nil, result, state), do: {:ok, result, state}

  defp call_handle_tool_result(module, result, state),
    do: module.handle_tool_result(result, state)

  defp call_handle_error(nil, _error, state), do: {:stop, state}
  defp call_handle_error(module, error, state), do: module.handle_error(error, state)

  defp call_terminate(nil, _reason, _state), do: :ok
  defp call_terminate(module, reason, state), do: module.terminate(reason, state)
end
