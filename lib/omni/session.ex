defmodule Omni.Session do
  @moduledoc """
  A persistent, branching wrapper around `Omni.Agent`.

  A Session owns a conversation identity, a branching message tree, a
  pluggable storage adapter, and a linked `Omni.Agent` process. It
  forwards the Agent's event stream to its own subscribers and commits
  turn messages to the tree, persisting through the store.

  ## Lifecycle

  Start a fresh session with an auto-generated id:

      {:ok, session} = Omni.Session.start_link(
        agent: [model: {:anthropic, "claude-sonnet-4-5"}],
        store: {Omni.Session.Store.FileSystem, base_path: "priv/sessions"},
        subscribe: true
      )

      :ok = Omni.Session.prompt(session, "Hello!")

  Or with an explicit id:

      {:ok, session} = Omni.Session.start_link(
        new: "conversation-42",
        agent: [...],
        store: [...]
      )

  Load an existing session:

      {:ok, session} = Omni.Session.start_link(
        load: "conversation-42",
        agent: [model: {:anthropic, "claude-sonnet-4-5"}],
        store: [...]
      )

  Both `:new` and `:load` are optional — omitting both is equivalent to
  `new: :auto`. Supplying both raises `{:error, :ambiguous_mode}`.

  ## Start options

    * `:new` — `binary()` or `:auto`. Start a fresh session with the
      given id, or an auto-generated one. Mutually exclusive with `:load`.
    * `:load` — `binary()`. Load an existing session by id. Mutually
      exclusive with `:new`.
    * `:agent` (required) — `keyword()` or `{module(), keyword()}`.
      Agent start options; the optional module is a callback module
      that `use Omni.Agent`.
    * `:store` (required) — `{module(), keyword()}` — a
      `Omni.Session.Store` adapter and its config.
    * `:title` — initial title string. Applied on `:new` only; ignored
      on `:load` (persisted title wins).
    * `:subscribe` — if `true`, subscribes the caller to session events.
    * `:subscribers` — list of pids to subscribe.
    * `:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug` —
      standard GenServer options.

  ### Load-mode resolution

  When loading, the persisted state is reconciled against start opts as
  follows:

  | Field | Resolution |
  |---|---|
  | `model` | Persisted first; falls back to start opt if unresolvable. `{:stop, :no_model}` if neither is usable. |
  | `system` | Start opt wins; falls back to persisted. |
  | `opts` | Start opt wins; falls back to persisted. |
  | `tools` | Start opt only. Never persisted (function refs). |
  | `title` | Persisted only. `title:` start option is ignored. |
  | `messages` | Derived from the persisted tree. `agent: [messages: _]` is silently ignored. |

  On `:new`, `agent: [messages: _]` is **rejected** with
  `{:error, :initial_messages_not_supported}` — the tree is the sole
  entry point for messages.

  ### Auto-generated ids

  `new: :auto` (and no mode supplied) generates 22-character URL-safe
  base64 with 128 bits of entropy:

      :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  ## Events

  Subscribers receive `{:session, pid, type, data}` messages, where the
  Agent's events are forwarded verbatim except for the tag change:

      {:agent, agent_pid, type, data}  →  {:session, session_pid, type, data}

  This includes streaming deltas, `:message`, `:step`, `:turn`,
  `:pause`, `:retry`, `:cancelled`, `:error`, `:state`, `:tool_result`.

  Session-specific events:

      {:session, pid, :tree,  %{tree: Tree.t(), new_nodes: [node_id()]}}
      {:session, pid, :store, {:saved, :tree | :state}}
      {:session, pid, :store, {:error, :tree | :state, reason}}

  At a turn commit, the event order is:

      :turn (forwarded) → :tree → :store {:saved, :tree}

  Session commits the segment's messages into the tree after forwarding
  the Agent's `:turn` event, then persists. Subscribers that want the
  logical turn boundary listen on `:turn`; subscribers that want the
  tree-structure change listen on `:tree`.

  ## Persistence

  Session writes through the store on two triggers:

    * **Turn commits** → `save_tree` with `:new_node_ids`, plus a
      `:tree` event and a `:store {:saved, :tree}` / `{:error, :tree, _}`
      event.
    * **Agent `:state` events** → `save_state` *only* when the
      persistable subset (`model`, `system`, `opts`, `title`) has
      changed since last write. Changes to `:tools` or `:private` do
      not trigger a write.

  All store calls are synchronous; Session **never halts** on store
  errors, only emits `:store {:error, _, _}`. Adapter-specific reasons
  (POSIX atoms, etc.) bubble up unwrapped.

  ## Linking and crash behaviour

  Session starts the Agent linked. Agent crashes propagate to the
  Session (no `trap_exit`) — an unhealthy Agent takes the Session down
  rather than limping on. Sessions are cheap to reopen via `load:`.

  When the Session stops gracefully, it stops the linked Agent as part
  of its termination.

  ## Pub/sub

  `subscribe/1,2` registers a pid and atomically returns an
  `%Omni.Session.Snapshot{}` capturing the current tree, title, and
  agent slice. Every event emitted after the subscribe call is
  delivered to the subscriber. Monitors clean up subscribers on death.
  """

  use GenServer

  alias Omni.Agent
  alias Omni.Agent.Snapshot, as: AgentSnapshot
  alias Omni.Session.{Snapshot, Store, Tree}

  @genserver_keys [:name, :timeout, :hibernate_after, :spawn_opt, :debug]
  @session_keys [:new, :load, :agent, :store, :title, :subscribe, :subscribers]

  defstruct [
    :id,
    :title,
    :tree,
    :store,
    :agent,
    subscribers: MapSet.new(),
    monitors: %{},
    last_persisted_state: nil
  ]

  # -- Public API --

  @doc """
  Starts a Session process linked to the caller.

  See the moduledoc for the full option list. `:agent` and `:store` are
  required.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gs_opts, opts} = Keyword.split(opts, @genserver_keys)
    # Capture $callers so Req.Test (and similar process-ownership
    # registries) can trace HTTP calls from inner Step tasks back to
    # the test process.
    callers = [self() | Process.get(:"$callers", [])]
    GenServer.start_link(__MODULE__, {callers, opts}, gs_opts)
  end

  @doc "Stops the Session gracefully. The linked Agent is stopped as part of termination."
  @spec stop(GenServer.server()) :: :ok
  def stop(session), do: GenServer.stop(session, :normal)

  @doc "Sends a prompt to the wrapped Agent. See `Omni.Agent.prompt/3`."
  @spec prompt(GenServer.server(), term(), keyword()) :: :ok
  def prompt(session, content, opts \\ []) do
    GenServer.call(session, {:prompt, content, opts})
  end

  @doc "Cancels the current turn. See `Omni.Agent.cancel/1`."
  @spec cancel(GenServer.server()) :: :ok | {:error, :idle}
  def cancel(session), do: GenServer.call(session, :cancel)

  @doc "Resumes a paused Agent. See `Omni.Agent.resume/2`."
  @spec resume(GenServer.server(), term()) :: :ok | {:error, :not_paused}
  def resume(session, decision), do: GenServer.call(session, {:resume, decision})

  @doc """
  Subscribes the caller to session events.

  Returns `{:ok, %Omni.Session.Snapshot{}}` — the snapshot captures the
  current tree, title, and a consistent agent slice at the instant of
  subscription. Subsequent events are delivered as `{:session, pid, type, data}`.
  """
  @spec subscribe(GenServer.server()) :: {:ok, Snapshot.t()}
  def subscribe(session), do: GenServer.call(session, :subscribe)

  @doc "Subscribes the given pid. Same semantics as `subscribe/1`."
  @spec subscribe(GenServer.server(), pid()) :: {:ok, Snapshot.t()}
  def subscribe(session, pid) when is_pid(pid),
    do: GenServer.call(session, {:subscribe, pid})

  @doc "Unsubscribes the caller from session events."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(session), do: GenServer.call(session, :unsubscribe)

  @doc "Unsubscribes the given pid from session events."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(session, pid) when is_pid(pid),
    do: GenServer.call(session, {:unsubscribe, pid})

  @doc "Returns an `%Omni.Session.Snapshot{}` of the session right now."
  @spec get_snapshot(GenServer.server()) :: Snapshot.t()
  def get_snapshot(session), do: GenServer.call(session, :get_snapshot)

  @doc "Returns the wrapped Agent's `%State{}`. See `Omni.Agent.get_state/1`."
  @spec get_agent(GenServer.server()) :: Agent.State.t()
  def get_agent(session), do: GenServer.call(session, :get_agent)

  @doc "Returns a single field from the wrapped Agent's state. See `Omni.Agent.get_state/2`."
  @spec get_agent(GenServer.server(), atom()) :: term()
  def get_agent(session, key) when is_atom(key),
    do: GenServer.call(session, {:get_agent, key})

  @doc "Returns the session's `%Omni.Session.Tree{}`."
  @spec get_tree(GenServer.server()) :: Tree.t()
  def get_tree(session), do: GenServer.call(session, :get_tree)

  @doc "Returns the session's title, or `nil` if unset."
  @spec get_title(GenServer.server()) :: String.t() | nil
  def get_title(session), do: GenServer.call(session, :get_title)

  @doc """
  Replaces Agent configuration fields. Passthrough to `Omni.Agent.set_state/2`.

  Changes to `:model`, `:system`, or `:opts` trigger a `save_state` via
  the `:state` event path; other settable keys do not persist.
  """
  @spec set_agent(GenServer.server(), keyword()) ::
          :ok | {:error, :running} | {:error, term()}
  def set_agent(session, opts) when is_list(opts),
    do: GenServer.call(session, {:set_agent, opts})

  @doc "Replaces or transforms a single Agent field. Passthrough to `Omni.Agent.set_state/3`."
  @spec set_agent(GenServer.server(), atom(), term() | (term() -> term())) ::
          :ok | {:error, :running} | {:error, term()}
  def set_agent(session, field, value_or_fun) when is_atom(field),
    do: GenServer.call(session, {:set_agent, field, value_or_fun})

  # -- Init --

  @impl GenServer
  def init({callers, opts}) do
    Process.put(:"$callers", callers)
    caller = hd(callers)

    with :ok <- validate_opts(opts),
         {:ok, id, mode} <- resolve_mode(opts),
         {:ok, tree, title, persistable, agent_opts} <- prepare(mode, id, opts),
         {:ok, agent_pid} <- start_agent(opts[:agent], agent_opts) do
      session =
        %__MODULE__{
          id: id,
          title: title,
          tree: tree,
          store: opts[:store],
          agent: agent_pid,
          last_persisted_state: persistable
        }
        |> add_initial_subscribers(caller, opts)

      {:ok, session}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp validate_opts(opts) do
    cond do
      Keyword.has_key?(opts, :new) and Keyword.has_key?(opts, :load) ->
        {:error, :ambiguous_mode}

      not Keyword.has_key?(opts, :agent) ->
        {:error, :missing_agent}

      not Keyword.has_key?(opts, :store) ->
        {:error, :missing_store}

      true ->
        :ok
    end
  end

  defp resolve_mode(opts) do
    cond do
      Keyword.has_key?(opts, :load) ->
        {:ok, Keyword.fetch!(opts, :load), :load}

      Keyword.has_key?(opts, :new) ->
        case Keyword.fetch!(opts, :new) do
          :auto -> {:ok, generate_id(), :new}
          id when is_binary(id) -> {:ok, id, :new}
        end

      true ->
        {:ok, generate_id(), :new}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # -- Mode-specific preparation --

  defp prepare(:new, _id, opts) do
    agent_opts = agent_start_opts(opts[:agent])

    case Keyword.get(agent_opts, :messages) do
      nil ->
        persistable = persistable_from_agent_opts(agent_opts, opts[:title])
        {:ok, %Tree{}, opts[:title], persistable, agent_opts}

      _ ->
        {:error, :initial_messages_not_supported}
    end
  end

  defp prepare(:load, id, opts) do
    case Store.load(opts[:store], id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, tree, state_map} ->
        reconcile_load(tree, state_map, opts)
    end
  end

  defp reconcile_load(tree, state_map, opts) do
    start_opts = agent_start_opts(opts[:agent])

    with {:ok, model_ref} <- resolve_loaded_model(state_map, start_opts) do
      system = Keyword.get(start_opts, :system, Map.get(state_map, :system))
      inference_opts = Keyword.get(start_opts, :opts, Map.get(state_map, :opts, []))
      tools = Keyword.get(start_opts, :tools, [])
      title = Map.get(state_map, :title)

      agent_opts =
        start_opts
        |> Keyword.delete(:messages)
        |> Keyword.put(:model, model_ref)
        |> Keyword.put(:system, system)
        |> Keyword.put(:opts, inference_opts)
        |> Keyword.put(:tools, tools)
        |> Keyword.put(:messages, Tree.messages(tree))

      persistable = %{
        model: model_ref,
        system: system,
        opts: Enum.sort(inference_opts),
        title: title
      }

      {:ok, tree, title, persistable, agent_opts}
    end
  end

  defp resolve_loaded_model(state_map, start_opts) do
    persisted = Map.get(state_map, :model)
    start_model = Keyword.get(start_opts, :model)

    cond do
      resolvable_model?(persisted) -> {:ok, persisted}
      resolvable_model?(start_model) -> {:ok, start_model}
      true -> {:error, :no_model}
    end
  end

  defp resolvable_model?(nil), do: false

  defp resolvable_model?({provider, id}) when is_atom(provider) and is_binary(id) do
    match?({:ok, _}, Omni.Model.get(provider, id))
  end

  defp resolvable_model?(%Omni.Model{}), do: true
  defp resolvable_model?(_), do: false

  defp agent_start_opts({_mod, opts}) when is_list(opts), do: opts
  defp agent_start_opts(opts) when is_list(opts), do: opts

  defp persistable_from_agent_opts(agent_opts, title) do
    %{
      model: normalise_model_ref(Keyword.get(agent_opts, :model)),
      system: Keyword.get(agent_opts, :system),
      opts: Enum.sort(Keyword.get(agent_opts, :opts, [])),
      title: title
    }
  end

  defp normalise_model_ref({provider, id}) when is_atom(provider) and is_binary(id),
    do: {provider, id}

  defp normalise_model_ref(%Omni.Model{} = model), do: Omni.Model.to_ref(model)
  defp normalise_model_ref(other), do: other

  # -- Agent startup --

  # Ensure Session is a subscriber from tick zero so no events race the
  # subscribe call. The user's `:subscribe` / `:subscribers` on the
  # agent opts — if any — apply to the caller, not to us.
  defp start_agent({mod, _}, reconciled) when is_atom(mod),
    do: Agent.start_link(mod, with_session_subscriber(reconciled))

  defp start_agent(_, reconciled) when is_list(reconciled),
    do: Agent.start_link(with_session_subscriber(reconciled))

  defp with_session_subscriber(opts) do
    existing = List.wrap(Keyword.get(opts, :subscribers, []))
    Keyword.put(opts, :subscribers, [self() | existing])
  end

  defp add_initial_subscribers(session, caller, opts) do
    caller_subs = if opts[:subscribe], do: [caller], else: []
    explicit = List.wrap(opts[:subscribers])

    Enum.reduce(caller_subs ++ explicit, session, fn pid, acc ->
      {acc, _snapshot} = subscribe_pid(acc, pid)
      acc
    end)
  end

  # -- Calls --

  @impl GenServer
  def handle_call({:prompt, content, opts}, _from, session) do
    {:reply, Agent.prompt(session.agent, content, opts), session}
  end

  def handle_call(:cancel, _from, session) do
    {:reply, Agent.cancel(session.agent), session}
  end

  def handle_call({:resume, decision}, _from, session) do
    {:reply, Agent.resume(session.agent, decision), session}
  end

  def handle_call(:subscribe, {pid, _}, session) do
    {session, snapshot} = subscribe_pid(session, pid)
    {:reply, {:ok, snapshot}, session}
  end

  def handle_call({:subscribe, pid}, _from, session) when is_pid(pid) do
    {session, snapshot} = subscribe_pid(session, pid)
    {:reply, {:ok, snapshot}, session}
  end

  def handle_call(:unsubscribe, {pid, _}, session) do
    {:reply, :ok, unsubscribe_pid(session, pid)}
  end

  def handle_call({:unsubscribe, pid}, _from, session) when is_pid(pid) do
    {:reply, :ok, unsubscribe_pid(session, pid)}
  end

  def handle_call(:get_snapshot, _from, session) do
    {:reply, build_snapshot(session), session}
  end

  def handle_call(:get_agent, _from, session) do
    {:reply, Agent.get_state(session.agent), session}
  end

  def handle_call({:get_agent, key}, _from, session) do
    {:reply, Agent.get_state(session.agent, key), session}
  end

  def handle_call(:get_tree, _from, session) do
    {:reply, session.tree, session}
  end

  def handle_call(:get_title, _from, session) do
    {:reply, session.title, session}
  end

  def handle_call({:set_agent, opts}, _from, session) do
    {:reply, Agent.set_state(session.agent, opts), session}
  end

  def handle_call({:set_agent, field, value_or_fun}, _from, session) do
    {:reply, Agent.set_state(session.agent, field, value_or_fun), session}
  end

  # -- Agent events --

  @impl GenServer
  def handle_info(
        {:agent, agent_pid, :turn, {_kind, response} = payload},
        %{agent: agent_pid} = session
      ) do
    # Compute the tree commit up front, but keep it off the session until
    # after the :turn event has been forwarded. Event order contract:
    # :turn → :tree → :store {:saved, :tree}.
    {new_tree, new_node_ids} = compute_tree_commit(response, session.tree)

    broadcast(session, :turn, payload)

    session = %{session | tree: new_tree}
    broadcast(session, :tree, %{tree: new_tree, new_nodes: new_node_ids})
    session = persist_tree(session, new_node_ids)

    {:noreply, session}
  end

  def handle_info(
        {:agent, agent_pid, :state, new_state},
        %{agent: agent_pid} = session
      ) do
    broadcast(session, :state, new_state)
    session = persist_state_if_changed(new_state, session)
    {:noreply, session}
  end

  def handle_info({:agent, agent_pid, type, payload}, %{agent: agent_pid} = session) do
    broadcast(session, type, payload)
    {:noreply, session}
  end

  # -- Subscriber monitor --

  def handle_info({:DOWN, ref, :process, _pid, _reason}, session) do
    case Map.pop(session.monitors, ref) do
      {nil, _} ->
        {:noreply, session}

      {pid, new_monitors} ->
        {:noreply,
         %{
           session
           | monitors: new_monitors,
             subscribers: MapSet.delete(session.subscribers, pid)
         }}
    end
  end

  def handle_info(_msg, session) do
    {:noreply, session}
  end

  # -- Terminate --

  @impl GenServer
  def terminate(_reason, session) do
    case session.agent do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          # Ignore exits from linked Agent so GenServer.stop can complete
          # even after the Agent goes down.
          Process.flag(:trap_exit, true)

          try do
            GenServer.stop(pid, :shutdown)
          catch
            :exit, _ -> :ok
          end
        end

      _ ->
        :ok
    end

    :ok
  end

  # -- Tree commit --

  # Append each message in the segment to the tree, attaching the
  # segment's usage to the last assistant. Because the Agent now
  # resets turn_usage per segment, response.usage is already the
  # segment-scoped total — Tree.usage/1 sums correctly across
  # multi-segment turns without double-counting.
  defp compute_tree_commit(response, tree) do
    messages = response.messages
    last_assistant = find_last_assistant(messages)

    {tree, ids} =
      Enum.reduce(messages, {tree, []}, fn msg, {t, ids} ->
        usage = if msg == last_assistant, do: response.usage, else: nil
        {id, t2} = Tree.push_node(t, msg, usage)
        {t2, [id | ids]}
      end)

    {tree, Enum.reverse(ids)}
  end

  defp find_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end

  # -- Persistence --

  defp persist_tree(session, new_node_ids) do
    case Store.save_tree(session.store, session.id, session.tree, new_node_ids: new_node_ids) do
      :ok ->
        broadcast(session, :store, {:saved, :tree})
        session

      {:error, reason} ->
        broadcast(session, :store, {:error, :tree, reason})
        session
    end
  end

  defp persist_state_if_changed(agent_state, session) do
    new_subset = persistable_subset(agent_state, session.title)

    if new_subset == session.last_persisted_state do
      session
    else
      case Store.save_state(session.store, session.id, new_subset) do
        :ok ->
          broadcast(session, :store, {:saved, :state})
          %{session | last_persisted_state: new_subset}

        {:error, reason} ->
          broadcast(session, :store, {:error, :state, reason})
          session
      end
    end
  end

  defp persistable_subset(agent_state, title) do
    %{
      model: Omni.Model.to_ref(agent_state.model),
      system: agent_state.system,
      opts: Enum.sort(agent_state.opts),
      title: title
    }
  end

  # -- Pub/sub --

  defp broadcast(session, type, payload) do
    msg = {:session, self(), type, payload}
    Enum.each(session.subscribers, &send(&1, msg))
    :ok
  end

  defp subscribe_pid(session, pid) do
    if MapSet.member?(session.subscribers, pid) do
      {session, build_snapshot(session)}
    else
      ref = Process.monitor(pid)

      session = %{
        session
        | subscribers: MapSet.put(session.subscribers, pid),
          monitors: Map.put(session.monitors, ref, pid)
      }

      {session, build_snapshot(session)}
    end
  end

  defp unsubscribe_pid(session, pid) do
    case find_monitor_ref(session.monitors, pid) do
      nil ->
        session

      ref ->
        Process.demonitor(ref, [:flush])

        %{
          session
          | subscribers: MapSet.delete(session.subscribers, pid),
            monitors: Map.delete(session.monitors, ref)
        }
    end
  end

  defp find_monitor_ref(monitors, pid) do
    Enum.find_value(monitors, fn {ref, mon_pid} -> mon_pid == pid && ref end)
  end

  defp build_snapshot(session) do
    agent_snapshot =
      case session.agent do
        pid when is_pid(pid) -> Agent.get_snapshot(pid)
        _ -> %AgentSnapshot{}
      end

    %Snapshot{
      id: session.id,
      title: session.title,
      tree: session.tree,
      agent: agent_snapshot
    }
  end

  @doc false
  # Exposed for static analysis / key validation in future work.
  def __session_keys__, do: @session_keys
end
