defmodule Omni.Session do
  @moduledoc """
  A Session wraps `Omni.Agent` with identity, persistence, and a
  branching message tree.

  Where an agent holds one in-memory conversation, a session adds the
  things you need to build a real application around it:

  - **Identity** — every session has an id. Grab it, hand it around,
    reopen the conversation later with `load: id`.
  - **A branching tree** — regenerate a turn, edit a user message,
    or switch between alternate replies. The full history stays in
    the tree; nothing is overwritten.
  - **Pluggable persistence** — turns commit through an
    `Omni.Session.Store` adapter. The reference adapter writes to
    disk; write your own for Postgres, S3, or anywhere else.

  Sessions otherwise behave like agents — prompt in, stream events out.
  Agent events are forwarded to Session subscribers re-tagged as
  `{:session, pid, type, data}`, alongside session-specific events for
  the tree, title, and store.

  ## Starting and resuming

  Every session has an id. Start a new one with `:new` (or omit for an
  auto-generated id), or reopen an existing one with `:load`.

      store = {Omni.Session.Store.FileSystem, base_path: "priv/sessions"}

      # Fresh session, auto-generated id
      {:ok, session} = Omni.Session.start_link(
        agent: [model: {:anthropic, "claude-sonnet-4-6"}],
        store: store,
        subscribe: true
      )

      :ok = Omni.Session.prompt(session, "Name three mountains.")

  Grab the id for later:

      id = Omni.Session.get_snapshot(session).id
      Omni.Session.stop(session)

  Reopen the same session in a new process, after a restart, or days
  later:

      {:ok, session} = Omni.Session.start_link(
        load: id,
        agent: [model: {:anthropic, "claude-sonnet-4-6"}],
        store: store
      )

  Load restores the persisted model, system prompt, opts, title, and
  full message tree. Tools are supplied fresh each boot — function
  references aren't safely serialisable. See **Load-mode resolution**
  below for field-by-field reconciliation between persisted state and
  start opts.

  Omitting both `:new` and `:load` is equivalent to `new: :auto`.
  Passing an explicit `new: "my-id"` that collides with an existing
  persisted session returns `{:error, :already_exists}`. Supplying
  both `:new` and `:load` raises `{:error, :ambiguous_mode}`.

  ## Branching and navigation

  The message tree lets a session carry multiple children at any node —
  alternate replies, edits, or scratch branches. Three operations cover
  the common UX:

      # Regenerate a turn — replay the target user message to get a
      # fresh assistant reply; the original reply stays as a sibling
      Omni.Session.branch(session, user_node_id)

      # Edit the next user message — append a new user + turn as a
      # child of the target assistant
      Omni.Session.branch(session, assistant_node_id, "Try it this way.")

      # Switch branches — move the active path to expose a different
      # branch as the live conversation
      Omni.Session.navigate(session, node_id)

  `branch/3` also accepts `nil` as the target to create a new disjoint
  root — the atomic equivalent of `navigate(session, nil)` followed by
  a fresh `prompt/3`. `navigate(session, nil)` on its own clears the
  active path; the next prompt then creates a new root.

  To explore the tree, use `Omni.Session.get_tree/1` with the
  `Omni.Session.Tree` helpers: `children/2`, `siblings/2`, `path_to/2`,
  and `Enumerable` over the active path.

  All three operations are idle-only — they return `{:error, status}`
  with the current status (`:busy` or `:paused`) when a turn is in flight.

  `navigate/2` always lands on a tip — after walking to the target it
  follows cursors down to a leaf so the resulting state is ready for a
  prompt. `branch/2,3` deliberately ends the in-flight window on a
  non-tip node; if that turn is cancelled or errors, the tree rolls back
  to its pre-branch state (also extended to a tip) — as if the branch
  was never started.

  ## Start options

  - `:new` — `binary()` or `:auto`. Start a fresh session with the
    given id, or an auto-generated one. Mutually exclusive with `:load`.
  - `:load` — `binary()`. Load an existing session by id. Mutually
    exclusive with `:new`.
  - `:agent` (required) — `keyword()` or `{module(), keyword()}`.
    Agent start options; the optional module is a callback module
    that `use Omni.Agent`.
  - `:store` (required) — `{module(), keyword()}` — a
    `Omni.Session.Store` adapter and its config.
  - `:title` — initial title string. Applied on `:new` only; ignored
    on `:load` (persisted title wins).
  - `:subscribe` — if `true`, subscribes the caller to session events
    as a `:controller` (see `subscribe/1,2` for mode semantics).
  - `:subscribers` — list of pids (implicit `:controller`) or
    `{pid, :controller | :observer}` tuples to subscribe at startup.
  - `:idle_shutdown_after` — `non_neg_integer()` (ms) or `nil`.
    When a positive integer, the session self-shuts-down when the
    last controller unsubscribes (or dies) and the agent becomes
    idle. Unset / `nil` (the default) keeps the session running
    until explicit stop. Init does not evaluate — shutdown is only
    evaluated on transitions (a controller leaving, the agent going
    idle).
  - `:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug` —
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

  `new: "explicit-id"` is **rejected** with `{:error, :already_exists}`
  when the id is already persisted in the store. `new: :auto` skips the
  check (128-bit entropy makes collision effectively impossible).

  ### Auto-generated ids

  `new: :auto` (and no mode supplied) generates 22-character URL-safe
  base64 with 128 bits of entropy:

      :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  ## Events

  Subscribers receive `{:session, pid, type, data}` messages. Most
  events are Agent events forwarded verbatim except for the tag change:

      {:agent, agent_pid, type, data}  →  {:session, session_pid, type, data}

  This includes streaming deltas, `:message`, `:step`, `:turn`,
  `:pause`, `:retry`, `:cancelled`, `:error`, `:state`, `:status`,
  `:tool_result`.

  Session-specific events:

      {:session, pid, :tree,  %{tree: Tree.t(), new_nodes: [node_id()]}}
      {:session, pid, :title, String.t() | nil}
      {:session, pid, :store, {:saved, :tree | :state}}
      {:session, pid, :store, {:error, :tree | :state, reason}}

  At a turn commit, the event order is:

      :turn (forwarded) → :tree → :store {:saved, :tree}

  Session commits the turn's messages into the tree after forwarding
  the Agent's `:turn` event, then persists. Subscribers that want the
  logical turn boundary listen on `:turn`; subscribers that want the
  tree-structure change listen on `:tree`.

  When a `branch/2,3` turn is cancelled or errors, Session rolls the
  tree back to its pre-branch state and resyncs the Agent. The order is:

      :cancelled (or :error) → :tree (restored) → :store {:saved, :tree}
        → :state (forwarded from the resync)

  ## Persistence

  Session writes through the store on two triggers:

  - **Turn commits** → `save_tree` with `:new_node_ids`, plus a
    `:tree` event and a `:store {:saved, :tree}` / `{:error, :tree, _}`
    event.
  - **Agent `:state` events** → `save_state` *only* when the
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

  `subscribe/1,2,3` registers a pid and atomically returns an
  `%Omni.Session.Snapshot{}` capturing the current tree, title, and
  agent slice. Every event emitted after the subscribe call is
  delivered to the subscriber. Monitors clean up subscribers on death.

  Subscribers have a `:mode` (default `:controller`). Controllers
  count toward keeping the session alive when `:idle_shutdown_after`
  is configured; observers receive events but never hold the session
  open. Subscriptions are idempotent per pid — re-subscribing with a
  different mode updates the mode in place.

  ## Going further

  For apps managing many concurrent sessions under one supervisor —
  with registry-backed id lookup and a live feed of session activity —
  see `Omni.Session.Manager`.
  """

  use GenServer

  alias Omni.Agent
  alias Omni.Agent.Snapshot, as: AgentSnapshot
  alias Omni.Session.{Snapshot, Store, Tree}

  @genserver_keys [:name, :timeout, :hibernate_after, :spawn_opt, :debug]
  @session_keys [
    :new,
    :load,
    :agent,
    :store,
    :title,
    :subscribe,
    :subscribers,
    :idle_shutdown_after
  ]

  defstruct [
    :id,
    :title,
    :tree,
    :store,
    :agent,
    subscribers: MapSet.new(),
    controllers: MapSet.new(),
    monitors: %{},
    agent_status: :idle,
    idle_shutdown_after: nil,
    shutdown_timer: nil,
    last_persisted_state: nil,
    regen_source: nil,
    pre_branch_tree: nil
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
  @spec resume(GenServer.server(), term()) :: :ok | {:error, :idle | :busy}
  def resume(session, decision), do: GenServer.call(session, {:resume, decision})

  @doc """
  Subscribes the caller to session events.

  Returns `{:ok, %Omni.Session.Snapshot{}}` — the snapshot captures the
  current tree, title, and a consistent agent slice at the instant of
  subscription. Subsequent events are delivered as
  `{:session, pid, type, data}`.

  Accepts `mode: :controller | :observer` (default `:controller`).
  Controllers count toward keeping the session alive when
  `:idle_shutdown_after` is configured; observers do not. Calling
  `subscribe/1,2` twice from the same pid is idempotent; passing a
  different mode on the second call updates the pid's mode in place.
  """
  @spec subscribe(GenServer.server()) :: {:ok, Snapshot.t()}
  def subscribe(session), do: subscribe(session, [])

  @doc """
  Subscribes the caller with opts, or subscribes a specific pid as
  `:controller`. Same semantics as `subscribe/1`.
  """
  @spec subscribe(GenServer.server(), keyword() | pid()) :: {:ok, Snapshot.t()}
  def subscribe(session, opts) when is_list(opts),
    do: GenServer.call(session, {:subscribe, :caller, opts})

  def subscribe(session, pid) when is_pid(pid),
    do: GenServer.call(session, {:subscribe, pid, []})

  @doc """
  Subscribes the given pid with opts. See `subscribe/2` for `:mode`.
  """
  @spec subscribe(GenServer.server(), pid(), keyword()) :: {:ok, Snapshot.t()}
  def subscribe(session, pid, opts) when is_pid(pid) and is_list(opts),
    do: GenServer.call(session, {:subscribe, pid, opts})

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
          :ok | {:error, :busy | :paused} | {:error, term()}
  def set_agent(session, opts) when is_list(opts),
    do: GenServer.call(session, {:set_agent, opts})

  @doc "Replaces or transforms a single Agent field. Passthrough to `Omni.Agent.set_state/3`."
  @spec set_agent(GenServer.server(), atom(), term() | (term() -> term())) ::
          :ok | {:error, :busy | :paused} | {:error, term()}
  def set_agent(session, field, value_or_fun) when is_atom(field),
    do: GenServer.call(session, {:set_agent, field, value_or_fun})

  @doc """
  Sets the active path to the node at `node_id` and extends down to a
  leaf via cursors. Pass `nil` to clear the path entirely.

  Walks parent pointers from `node_id` back to root, then follows cursors
  forward to the most-recently-active leaf — so navigation always lands
  on the tip of a branch, ready for a prompt. The wrapped Agent is
  resynced via `Omni.Agent.set_state(messages: _)` with the new path's
  messages.

  Use `branch/2,3` instead when you want the path to end on a non-tip
  node (regen, edit, new root).

  Idle-only: returns `{:error, status}` with the current status (`:busy`
  or `:paused`) when a turn is in flight.
  """
  @spec navigate(GenServer.server(), Tree.node_id() | nil) ::
          :ok | {:error, :not_found | :busy | :paused | term()}
  def navigate(session, node_id), do: GenServer.call(session, {:navigate, node_id})

  @doc """
  Branches from `node_id`, reusing the target's user content to
  regenerate its turn. `node_id` must reference a user node.

  The active path ends on the user for the in-flight window; the Agent
  sees messages up to and including the user's parent. On turn commit,
  the leading (duplicate) user message is dropped and the remainder is
  pushed as children of `node_id`.

  Idle-only: returns `{:error, status}` with the current status (`:busy`
  or `:paused`) when a turn is in flight.
  """
  @spec branch(GenServer.server(), Tree.node_id()) ::
          :ok | {:error, :not_found | :busy | :paused | :not_user_node | term()}
  def branch(session, node_id), do: GenServer.call(session, {:branch, node_id})

  @doc """
  Branches from `node_id` with new user content.

  - When `node_id` is an assistant node, the new user + its turn
    appends as children of the assistant — "edit the next user
    message."
  - When `node_id` is `nil`, creates a new disjoint root with the
    given content — the atomic equivalent of `navigate(session,
    nil)` followed by `prompt(session, content)`.

  Idle-only: returns `{:error, status}` with the current status (`:busy`
  or `:paused`) when a turn is in flight.
  """
  @spec branch(GenServer.server(), Tree.node_id() | nil, term()) ::
          :ok | {:error, :not_found | :busy | :paused | :not_assistant_node | term()}
  def branch(session, node_id, content),
    do: GenServer.call(session, {:branch, node_id, content})

  @doc """
  Sets the session title. Emits a `:title` event and triggers a
  `save_state` via the persistable-subset change-detection path (a
  same-value set is a no-op).
  """
  @spec set_title(GenServer.server(), String.t() | nil) :: :ok
  def set_title(session, title), do: GenServer.call(session, {:set_title, title})

  @doc """
  Appends a tool to the wrapped Agent's tools. Convenience over
  `set_agent(:tools, _)`. Tools are not persisted.
  """
  @spec add_tool(GenServer.server(), Omni.Tool.t()) ::
          :ok | {:error, :busy | :paused} | {:error, term()}
  def add_tool(session, tool), do: set_agent(session, :tools, &(&1 ++ [tool]))

  @doc """
  Removes the tool with the given name from the wrapped Agent. Silent
  no-op if no matching tool exists.
  """
  @spec remove_tool(GenServer.server(), String.t()) ::
          :ok | {:error, :busy | :paused} | {:error, term()}
  def remove_tool(session, tool_name) when is_binary(tool_name),
    do: set_agent(session, :tools, &Enum.reject(&1, fn t -> t.name == tool_name end))

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
          idle_shutdown_after: Keyword.get(opts, :idle_shutdown_after),
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

      not valid_idle_shutdown_after?(opts[:idle_shutdown_after]) ->
        {:error, :invalid_idle_shutdown_after}

      true ->
        :ok
    end
  end

  defp valid_idle_shutdown_after?(nil), do: true
  defp valid_idle_shutdown_after?(ms) when is_integer(ms) and ms >= 0, do: true
  defp valid_idle_shutdown_after?(_), do: false

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

  defp prepare(:new, id, opts) do
    agent_opts = agent_start_opts(opts[:agent])

    cond do
      Keyword.get(agent_opts, :messages) != nil ->
        {:error, :initial_messages_not_supported}

      explicit_new_id?(opts) and Store.exists?(opts[:store], id) ->
        {:error, :already_exists}

      true ->
        persistable = persistable_from_agent_opts(agent_opts, opts[:title])
        {:ok, %Tree{}, opts[:title], persistable, agent_opts}
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

  defp explicit_new_id?(opts) do
    case Keyword.get(opts, :new) do
      id when is_binary(id) -> true
      _ -> false
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

    Enum.reduce(caller_subs ++ explicit, session, fn entry, acc ->
      {pid, mode} =
        case entry do
          pid when is_pid(pid) -> {pid, :controller}
          {pid, mode} when is_pid(pid) -> {pid, mode}
        end

      {acc, _snapshot} = do_subscribe(acc, pid, mode)
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

  def handle_call({:subscribe, :caller, opts}, {pid, _}, session) do
    mode = Keyword.get(opts, :mode, :controller)
    {session, snapshot} = do_subscribe(session, pid, mode)
    {:reply, {:ok, snapshot}, session}
  end

  def handle_call({:subscribe, pid, opts}, _from, session) when is_pid(pid) do
    mode = Keyword.get(opts, :mode, :controller)
    {session, snapshot} = do_subscribe(session, pid, mode)
    {:reply, {:ok, snapshot}, session}
  end

  def handle_call(:unsubscribe, {pid, _}, session) do
    {:reply, :ok, do_unsubscribe(session, pid)}
  end

  def handle_call({:unsubscribe, pid}, _from, session) when is_pid(pid) do
    {:reply, :ok, do_unsubscribe(session, pid)}
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

  def handle_call({:navigate, node_id}, _from, session) do
    with :ok <- require_idle(session),
         {:ok, session} <- apply_navigation(session, node_id, &Tree.messages/1, extend: true) do
      {:reply, :ok, session}
    else
      {:error, _} = error -> {:reply, error, session}
    end
  end

  def handle_call({:branch, node_id}, _from, session) do
    pre_tree = session.tree

    with :ok <- require_idle(session),
         {:ok, node} <- fetch_node(session.tree, node_id),
         :ok <- require_role(node, :user, :not_user_node),
         parent_messages_fn = &Enum.drop(Tree.messages(&1), -1),
         {:ok, session} <- apply_navigation(session, node_id, parent_messages_fn) do
      session = %{session | regen_source: node_id, pre_branch_tree: pre_tree}
      :ok = Agent.prompt(session.agent, node.message.content)
      {:reply, :ok, session}
    else
      {:error, _} = error -> {:reply, error, session}
    end
  end

  def handle_call({:branch, nil, content}, _from, session) do
    pre_tree = session.tree

    with :ok <- require_idle(session),
         {:ok, session} <- apply_navigation(session, nil, fn _ -> [] end) do
      session = %{session | pre_branch_tree: pre_tree}
      :ok = Agent.prompt(session.agent, content)
      {:reply, :ok, session}
    else
      {:error, _} = error -> {:reply, error, session}
    end
  end

  def handle_call({:branch, node_id, content}, _from, session) do
    pre_tree = session.tree

    with :ok <- require_idle(session),
         {:ok, node} <- fetch_node(session.tree, node_id),
         :ok <- require_role(node, :assistant, :not_assistant_node),
         {:ok, session} <- apply_navigation(session, node_id, &Tree.messages/1) do
      session = %{session | pre_branch_tree: pre_tree}
      :ok = Agent.prompt(session.agent, content)
      {:reply, :ok, session}
    else
      {:error, _} = error -> {:reply, error, session}
    end
  end

  def handle_call({:set_title, title}, _from, session) do
    session = %{session | title: title}
    broadcast(session, :title, title)
    agent_state = Agent.get_state(session.agent)
    session = persist_state_if_changed(agent_state, session)
    {:reply, :ok, session}
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
    {messages, session} = consume_regen_source(response.messages, session)
    {new_tree, new_node_ids} = compute_tree_commit(messages, response.usage, session.tree)

    broadcast(session, :turn, payload)

    session = %{session | tree: new_tree, pre_branch_tree: nil}
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

  def handle_info(
        {:agent, agent_pid, :status, status},
        %{agent: agent_pid} = session
      ) do
    session = %{session | agent_status: status}
    broadcast(session, :status, status)

    session =
      case status do
        :idle -> maybe_schedule_shutdown(session)
        _ -> cancel_shutdown_timer(session)
      end

    {:noreply, session}
  end

  def handle_info(
        {:agent, agent_pid, type, payload},
        %{agent: agent_pid, pre_branch_tree: pre_tree} = session
      )
      when pre_tree != nil and type in [:cancelled, :error] do
    broadcast(session, type, payload)

    restored = Tree.extend(pre_tree)
    :ok = Agent.set_state(session.agent, messages: Tree.messages(restored))

    session = %{session | tree: restored, regen_source: nil, pre_branch_tree: nil}
    broadcast(session, :tree, %{tree: restored, new_nodes: []})
    session = persist_tree(session, [])

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
        was_controller = MapSet.member?(session.controllers, pid)

        session = %{
          session
          | monitors: new_monitors,
            subscribers: MapSet.delete(session.subscribers, pid),
            controllers: MapSet.delete(session.controllers, pid)
        }

        session = if was_controller, do: maybe_schedule_shutdown(session), else: session
        {:noreply, session}
    end
  end

  # -- Idle shutdown --

  def handle_info(:idle_shutdown, session) do
    session = %{session | shutdown_timer: nil}

    if shutdown_conditions_met?(session) do
      {:stop, :normal, session}
    else
      {:noreply, session}
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

  # Append each turn message to the tree, attaching the turn's usage
  # to its last assistant. Because the Agent resets turn_usage per
  # turn, `usage` is already the turn-scoped total — Tree.usage/1 sums
  # correctly across continuations without double-counting.
  defp compute_tree_commit(messages, usage, tree) do
    last_assistant = find_last_assistant(messages)

    {tree, ids} =
      Enum.reduce(messages, {tree, []}, fn msg, {t, ids} ->
        u = if msg == last_assistant, do: usage, else: nil
        {id, t2} = Tree.push_node(t, msg, u)
        {t2, [id | ids]}
      end)

    {tree, Enum.reverse(ids)}
  end

  defp find_last_assistant(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :assistant))
  end

  # Regen (`branch/2`) navigates the tree path to the target user and
  # records the user's id in `regen_source`. On the first :turn commit
  # after that, we drop the leading (duplicate) user from the response
  # and clear the flag — any following continuation turns push normally.
  defp consume_regen_source(messages, %{regen_source: nil} = session),
    do: {messages, session}

  defp consume_regen_source([_duplicate_user | rest], session),
    do: {rest, %{session | regen_source: nil}}

  # -- Target validation --

  defp require_idle(session) do
    case Agent.get_state(session.agent, :status) do
      :idle -> :ok
      status -> {:error, status}
    end
  end

  defp fetch_node(tree, node_id) do
    case Tree.get_node(tree, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp require_role(%{message: %{role: role}}, role, _err), do: :ok
  defp require_role(_node, _role, err), do: {:error, err}

  # Shared backbone for navigate/branch handle_call clauses. Walks the
  # tree to `target`, resyncs the Agent's committed messages, broadcasts
  # `:tree`, and persists. `messages_fn` derives the Agent message list
  # from the new tree (full path, parent path, or `[]`). Pass
  # `extend: true` (used by `navigate/2`) to follow cursors down to a
  # leaf after navigating; branch call sites omit it because they need
  # the path to end exactly on the navigation target.
  defp apply_navigation(session, target, messages_fn, opts \\ []) do
    with {:ok, new_tree} <- Tree.navigate(session.tree, target),
         new_tree = maybe_extend(new_tree, opts[:extend]),
         messages = messages_fn.(new_tree),
         :ok <- Agent.set_state(session.agent, messages: messages) do
      session = %{session | tree: new_tree}
      broadcast(session, :tree, %{tree: new_tree, new_nodes: []})
      session = persist_tree(session, [])
      {:ok, session}
    end
  end

  defp maybe_extend(tree, true), do: Tree.extend(tree)
  defp maybe_extend(tree, _), do: tree

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

  defp do_subscribe(session, pid, mode) when mode in [:controller, :observer] do
    session =
      if MapSet.member?(session.subscribers, pid) do
        session
      else
        ref = Process.monitor(pid)

        %{
          session
          | subscribers: MapSet.put(session.subscribers, pid),
            monitors: Map.put(session.monitors, ref, pid)
        }
      end

    session =
      case mode do
        :controller ->
          %{session | controllers: MapSet.put(session.controllers, pid)}
          |> cancel_shutdown_timer()

        :observer ->
          if MapSet.member?(session.controllers, pid) do
            %{session | controllers: MapSet.delete(session.controllers, pid)}
            |> maybe_schedule_shutdown()
          else
            session
          end
      end

    {session, build_snapshot(session)}
  end

  defp do_unsubscribe(session, pid) do
    case find_monitor_ref(session.monitors, pid) do
      nil ->
        session

      ref ->
        Process.demonitor(ref, [:flush])
        was_controller = MapSet.member?(session.controllers, pid)

        session = %{
          session
          | subscribers: MapSet.delete(session.subscribers, pid),
            controllers: MapSet.delete(session.controllers, pid),
            monitors: Map.delete(session.monitors, ref)
        }

        if was_controller, do: maybe_schedule_shutdown(session), else: session
    end
  end

  defp find_monitor_ref(monitors, pid) do
    Enum.find_value(monitors, fn {ref, mon_pid} -> mon_pid == pid && ref end)
  end

  # -- Idle shutdown helpers --

  defp shutdown_conditions_met?(session) do
    MapSet.size(session.controllers) == 0 and
      session.agent_status == :idle and
      not is_nil(session.idle_shutdown_after)
  end

  defp maybe_schedule_shutdown(%{shutdown_timer: ref} = session) when is_reference(ref) do
    # A timer is already armed; leave it alone.
    session
  end

  defp maybe_schedule_shutdown(session) do
    if shutdown_conditions_met?(session) do
      ref = Process.send_after(self(), :idle_shutdown, session.idle_shutdown_after)
      %{session | shutdown_timer: ref}
    else
      session
    end
  end

  defp cancel_shutdown_timer(%{shutdown_timer: nil} = session), do: session

  defp cancel_shutdown_timer(%{shutdown_timer: ref} = session) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{session | shutdown_timer: nil}
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
