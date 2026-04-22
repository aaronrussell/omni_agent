defmodule Omni.Agent.Server do
  @moduledoc false

  # Lifecycle: turn > segment > step
  #
  #   prompt/3 ──► TURN START
  #   │
  #   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete ──► :step event
  #   │   └─ tool_use? ──► handle_tool_decision_phase ──► spawn_executor
  #   ├─ evaluate_head ──► user msg ──► spawn_step ──► handle_step_complete ──► :step event
  #   │   └─ tool_use? ──► ...repeat...
  #   └─ evaluate_head ──► assistant (no tools) ──► finalize_turn ──► handle_turn
  #       ├─ {:continue, prompt} ──► :turn {:continue, _} ──► new segment
  #       └─ {:stop, state}       ──► :turn {:stop, _}     ──► TURN END
  #
  # Commit happens on every :turn event — both variants flush turn_messages
  # into state.messages. A segment is the span of turn_messages between commits.

  use GenServer

  alias Omni.{Context, Message, Model, Response, Tool, Usage}
  alias Omni.Agent.{Snapshot, State}
  alias Omni.Content.{ToolResult, ToolUse}

  defstruct [
    # Public state (passed to callbacks)
    :state,

    # Configuration (set at init, stable across turns)
    :module,
    :tool_timeout,

    # Pub/sub
    # subscribers: MapSet of pids receiving events
    # monitors: %{ref => pid} — demonitor by ref, remove pid on :DOWN
    subscribers: MapSet.new(),
    monitors: %{},

    # Turn lifecycle (set when a prompt starts, cleared by reset_turn).
    #
    # Naming mirrors the event hierarchy: :message < :step < :turn.
    #
    # step_message: the current step's user message (initial prompt, a
    #   continuation prompt, or the tool-result user message). Paired with
    #   the assistant response when emitting :step so :step.response.messages
    #   is always [user, assistant].
    # turn_messages: messages accumulated in the current segment (committed
    #   on every :turn event, cleared between segments). A segment is
    #   always 2n messages — user/assistant pairs.
    # turn_usage: accumulated usage for the current turn across all steps.
    # prompt_opts: merged opts for the current turn (state.opts + call-site opts).
    # next_prompt: staged {content, opts} tuple, set when prompt/3 is called
    #   while running/paused.
    # partial_message: current streaming assistant message, or nil. Updated
    #   from Step events; cleared on :message emission and reset_turn.
    step_message: nil,
    turn_messages: [],
    turn_usage: %Usage{},
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
    paused_use: nil,
    paused_reason: nil
  ]

  @settable_fields [:model, :system, :messages, :tools, :opts]

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

    with {:ok, model} <- resolve_model(opts[:model]),
         initial_state = build_initial_state(model, opts),
         {:ok, %State{} = state} <- call_init(module, initial_state),
         :ok <- State.validate_messages(state.messages) do
      caller = hd(callers)

      initial_subs =
        List.wrap(opts[:subscribers]) ++
          if(opts[:subscribe], do: [caller], else: [])

      server =
        %__MODULE__{
          state: state,
          module: module,
          tool_timeout: Keyword.get(opts, :tool_timeout, 5_000)
        }
        |> add_initial_subscribers(initial_subs)

      {:ok, server}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp add_initial_subscribers(server, pids) do
    Enum.reduce(pids, server, fn pid, acc when is_pid(pid) ->
      {acc, _snapshot} = subscribe_pid(acc, pid)
      acc
    end)
  end

  defp resolve_model({provider_id, model_id}), do: Model.get(provider_id, model_id)
  defp resolve_model(%Model{} = model), do: {:ok, model}
  defp resolve_model(nil), do: {:error, :missing_model}

  defp build_initial_state(model, opts) do
    %State{
      model: model,
      system: opts[:system],
      messages: opts[:messages] || [],
      tools: opts[:tools] || [],
      opts: Keyword.get(opts, :opts, []),
      private: opts[:private] || %{}
    }
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
        {:prompt, content, opts},
        _from,
        %__MODULE__{state: %{status: status}} = server
      )
      when status in [:running, :paused] do
    {:reply, :ok, %{server | next_prompt: {content, opts}}}
  end

  def handle_call({:resume, decision}, _from, %__MODULE__{state: %{status: :paused}} = server) do
    tool_use = server.paused_use

    server = %{
      server
      | state: %{server.state | status: :running},
        paused_use: nil,
        paused_reason: nil
    }

    notify(server, :status, :running)

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

  # -- Subscribe / snapshot --

  def handle_call(:subscribe, {pid, _}, server) do
    {server, snapshot} = subscribe_pid(server, pid)
    {:reply, {:ok, snapshot}, server}
  end

  def handle_call({:subscribe, pid}, _from, server) when is_pid(pid) do
    {server, snapshot} = subscribe_pid(server, pid)
    {:reply, {:ok, snapshot}, server}
  end

  def handle_call(:unsubscribe, {pid, _}, server) do
    {:reply, :ok, unsubscribe_pid(server, pid)}
  end

  def handle_call({:unsubscribe, pid}, _from, server) when is_pid(pid) do
    {:reply, :ok, unsubscribe_pid(server, pid)}
  end

  def handle_call(:get_snapshot, _from, server) do
    {:reply, build_snapshot(server), server}
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
        notify(server, :state, new_state)
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

    with {:ok, resolved} <- maybe_resolve_field(field, new_value),
         :ok <- maybe_validate_field(field, resolved) do
      new_state = Map.put(server.state, field, resolved)
      server = %{server | state: new_state}
      notify(server, :state, new_state)
      {:reply, :ok, server}
    else
      {:error, _} = error -> {:reply, error, server}
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

  # -- Info (step messages) --

  @impl GenServer
  def handle_info({ref, {:event, type, event_map, partial}}, %{step_task: {_, ref}} = server) do
    server = %{server | partial_message: partial_message_from(partial)}
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
        server = reset_turn(%{server | state: new_state})
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
        server = reset_turn(%{server | state: new_state})
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
    server = reset_turn(server)
    notify(server, :error, error)
    {:noreply, server}
  end

  # -- Info (subscriber monitors) --

  def handle_info({:DOWN, ref, :process, _pid, _reason}, server) do
    case Map.pop(server.monitors, ref) do
      {nil, _} ->
        {:noreply, server}

      {pid, new_monitors} ->
        {:noreply,
         %{
           server
           | monitors: new_monitors,
             subscribers: MapSet.delete(server.subscribers, pid)
         }}
    end
  end

  def handle_info(_msg, server) do
    {:noreply, server}
  end

  # -- Terminate --

  @impl GenServer
  def terminate(reason, server) do
    call_terminate(server.module, reason, server.state)
  end

  # -- Turn start --

  defp start_turn(content, opts, server) do
    user_message = Message.new(role: :user, content: content)
    prompt_opts = Keyword.merge(server.state.opts, opts)

    %{
      server
      | state: %{server.state | status: :running, step: 0},
        step_message: user_message,
        turn_messages: [user_message],
        prompt_opts: prompt_opts
    }
    |> tap(&notify(&1, :status, :running))
    |> tap(&notify(&1, :message, user_message))
    |> evaluate_head()
  end

  # -- evaluate_head: unified state machine --

  defp evaluate_head(server) do
    if max_steps_reached?(server) do
      finalize_turn(server.last_response, server)
    else
      last_message = List.last(server.turn_messages)

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
      messages: server.state.messages ++ server.turn_messages,
      tools: server.state.tools
    }
  end

  # -- Step completion --

  defp handle_step_complete(response, server) do
    turn_usage = Usage.add(server.turn_usage, response.usage)
    step_messages = [server.step_message, response.message]

    server = %{
      server
      | turn_messages: server.turn_messages ++ [response.message],
        step_task: nil,
        last_response: response,
        turn_usage: turn_usage,
        partial_message: nil
    }

    notify(server, :message, response.message)
    notify(server, :step, %{response | messages: step_messages})
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
            paused_use: tool_use,
            paused_reason: reason
        }
        |> tap(&notify(&1, :status, :paused))
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

    # Call handle_tool_result for each and notify listener
    {final_results, server} =
      Enum.map_reduce(all_results, server, fn result, srv ->
        case call_handle_tool_result(srv.module, result, srv.state) do
          {:ok, final_result, new_state} ->
            srv = %{srv | state: new_state}

            notify(srv, :tool_result, final_result)

            {final_result, srv}
        end
      end)

    # Build user message with all tool results, append to turn
    user_message = Message.new(role: :user, content: final_results)

    server = %{
      server
      | step_message: user_message,
        turn_messages: server.turn_messages ++ [user_message]
    }

    notify(server, :message, user_message)
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
    {segment, usage, server} = commit_segment(server)
    response = build_turn_response(server, segment, usage)
    notify(server, :turn, {:continue, response})

    user_message = Message.new(role: :user, content: prompt)
    server = %{server | step_message: user_message, turn_messages: [user_message]}
    notify(server, :message, user_message)
    evaluate_head(server)
  end

  defp complete_turn(_response, server) do
    {segment, usage, server} = commit_segment(server)
    response = build_turn_response(server, segment, usage)
    server = reset_turn(server)
    notify(server, :turn, {:stop, response})
    server
  end

  # Flushes the current segment into state.messages and resets segment
  # accumulators. Returns the flushed messages and the segment's usage
  # so the :turn response reflects just this segment — multi-segment
  # turns then carry per-segment usage instead of cumulative.
  defp commit_segment(server) do
    segment = server.turn_messages
    usage = server.turn_usage
    new_messages = server.state.messages ++ segment

    server = %{
      server
      | state: %{server.state | messages: new_messages},
        turn_messages: [],
        turn_usage: %Usage{}
    }

    {segment, usage, server}
  end

  # -- Cancel --

  defp do_cancel(server) do
    kill_task(server.step_task)
    kill_task(server.executor_task)

    response = build_cancel_response(server)
    server = reset_turn(server)
    notify(server, :cancelled, response)
    server
  end

  defp kill_task(nil), do: :ok
  defp kill_task({pid, _ref}), do: Process.exit(pid, :kill)

  # -- Response builders --

  defp build_turn_response(server, segment_messages, usage) do
    last_assistant = find_last_assistant(segment_messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: segment_messages,
      output: if(server.last_response, do: server.last_response.output),
      stop_reason: if(server.last_response, do: server.last_response.stop_reason, else: :stop),
      usage: usage
    }
  end

  defp build_cancel_response(server) do
    last_assistant = find_last_assistant(server.turn_messages)

    %Response{
      model: server.state.model,
      message: last_assistant,
      messages: server.turn_messages,
      stop_reason: :cancelled,
      usage: server.turn_usage
    }
  end

  defp find_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end

  # -- set_state --

  defp apply_set_state(state, opts) do
    with :ok <- validate_set_state_keys(opts),
         :ok <- validate_set_state_messages(opts),
         {:ok, state} <- maybe_resolve_model(state, opts) do
      state =
        Enum.reduce(opts, state, fn
          {:model, _}, acc -> acc
          {key, value}, acc -> Map.put(acc, key, value)
        end)

      {:ok, state}
    end
  end

  defp validate_set_state_messages(opts) do
    case Keyword.fetch(opts, :messages) do
      {:ok, messages} -> State.validate_messages(messages)
      :error -> :ok
    end
  end

  defp maybe_validate_field(:messages, value), do: State.validate_messages(value)
  defp maybe_validate_field(_field, _value), do: :ok

  defp validate_set_state_keys(opts) do
    case Enum.find(opts, fn {key, _} -> key not in @settable_fields end) do
      nil -> :ok
      {key, _} -> {:error, {:invalid_key, key}}
    end
  end

  defp maybe_resolve_model(state, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model_ref} ->
        case resolve_model(model_ref) do
          {:ok, model} -> {:ok, %{state | model: model}}
          {:error, _} -> {:error, {:model_not_found, model_ref}}
        end

      :error ->
        {:ok, state}
    end
  end

  defp maybe_resolve_field(:model, value) do
    case resolve_model(value) do
      {:ok, model} -> {:ok, model}
      {:error, _} -> {:error, {:model_not_found, value}}
    end
  end

  defp maybe_resolve_field(_field, value), do: {:ok, value}

  # -- Helpers --

  defp reset_turn(server) do
    old_status = server.state.status

    server = %{
      server
      | state: %{server.state | status: :idle, step: 0},
        step_message: nil,
        turn_messages: [],
        turn_usage: %Usage{},
        step_task: nil,
        executor_task: nil,
        rejected_results: [],
        provided_results: [],
        next_prompt: nil,
        prompt_opts: [],
        last_response: nil,
        partial_message: nil,
        tool_map: nil,
        approved_uses: [],
        remaining_uses: [],
        paused_use: nil,
        paused_reason: nil
    }

    if old_status != :idle, do: notify(server, :status, :idle)
    server
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

  defp subscribe_pid(server, pid) do
    if MapSet.member?(server.subscribers, pid) do
      {server, build_snapshot(server)}
    else
      ref = Process.monitor(pid)

      server = %{
        server
        | subscribers: MapSet.put(server.subscribers, pid),
          monitors: Map.put(server.monitors, ref, pid)
      }

      {server, build_snapshot(server)}
    end
  end

  defp unsubscribe_pid(server, pid) do
    case find_monitor_ref(server.monitors, pid) do
      nil ->
        server

      ref ->
        Process.demonitor(ref, [:flush])

        %{
          server
          | subscribers: MapSet.delete(server.subscribers, pid),
            monitors: Map.delete(server.monitors, ref)
        }
    end
  end

  defp find_monitor_ref(monitors, pid) do
    Enum.find_value(monitors, fn {ref, mon_pid} -> mon_pid == pid && ref end)
  end

  defp build_snapshot(server) do
    %Snapshot{
      state: server.state,
      pending: server.turn_messages,
      partial: server.partial_message
    }
  end

  defp partial_message_from(%Response{message: %Message{} = msg}), do: msg
  defp partial_message_from(_), do: nil

  # -- Callback dispatch --

  defp call_init(nil, state), do: {:ok, state}
  defp call_init(module, state), do: module.init(state)

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
