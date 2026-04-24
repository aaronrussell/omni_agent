defmodule Omni.Session.Manager do
  @moduledoc """
  Supervises many `Omni.Session` processes and provides id-based
  lifecycle management.

  The Manager is an app-level Supervisor. Apps define their own module
  that `use`s it — following the `Ecto.Repo` convention — and drop that
  module into a supervision tree:

      defmodule MyApp.Sessions do
        use Omni.Session.Manager
      end

      # application.ex
      children = [
        {MyApp.Sessions,
           store: {Omni.Session.Store.FileSystem, base_path: "priv/sessions"}}
      ]

  Call sites go through the `use`-generated shorthand:

      {:ok, pid}             = MyApp.Sessions.create(agent: [model: {:anthropic, "claude-sonnet-4-5"}])
      {:ok, :started, pid}   = MyApp.Sessions.open("abc-123")
      :ok                    = MyApp.Sessions.close("abc-123")
      {:ok, sessions}        = MyApp.Sessions.list(limit: 50)

  ## What the Manager supervises

      MyApp.Sessions (Supervisor, :rest_for_one)
      ├── MyApp.Sessions.Registry (Registry, keys: :unique)
      ├── MyApp.Sessions.DynamicSupervisor (DynamicSupervisor)
      └── MyApp.Sessions.Tracker (GenServer)

  Sessions live under the DynamicSupervisor with `restart: :temporary` —
  on crash they do not auto-restart. The Registry maps session ids to
  pids; on `close/2` or crash, entries are removed automatically. The
  Tracker observes every running session and powers `list_open/1`
  plus the Manager-level `subscribe/1` feed.

  Running sessions outlive the caller that created them. The caller is
  auto-subscribed as a `:controller` by default, so idle-shutdown kicks
  in once the caller drops off (see `:idle_shutdown_after`).

  ## Cross-session view

  `list_open/1` returns a snapshot of all running sessions; each
  entry is `%{id, title, status, pid}`. `subscribe/1` atomically returns
  the same snapshot and starts streaming live events to the caller:

      {:manager, MyApp.Sessions, :session_added,   %{id, title, status, pid}}
      {:manager, MyApp.Sessions, :session_status,  %{id, status}}
      {:manager, MyApp.Sessions, :session_title,   %{id, title}}
      {:manager, MyApp.Sessions, :session_removed, %{id}}

  The second element is the Manager module — what the caller already
  holds — so subscribers watching multiple Managers route events by
  pattern-matching.

  ## Configuration

    * `:store` — **required**. `{module, keyword()}` — the store adapter
      tuple. Used by every session this Manager starts, and by `list/2`
      and `delete/2`.
    * `:idle_shutdown_after` — `nil | non_neg_integer()`. Default for
      sessions this Manager starts; overridden per-call. Defaults to
      `300_000` (5 minutes) when absent. Pass `nil` to disable
      Manager-wide.
    * `:name` — overrides the registered name. Defaults to the `use`-ing
      module.

  ## `open/3` return shape

  `open/3` tells you whether the Manager actually started the session or
  attached to an already-running one:

      {:ok, :started, pid}   # Manager started the process; opts applied
      {:ok, :existing, pid}  # process was already up; opts silently dropped

  On the `:existing` branch, start-time opts (`:agent`, `:title`,
  `:idle_shutdown_after`, `:subscribers`) are dropped because mutating a
  live session's configuration safely requires knowing its agent status.
  Callers who genuinely need fresh config use `close/2` + `open/3`.

  `:subscribe` is honored in both branches — it is a subscription, not a
  state mutation.
  """

  use Supervisor

  alias Omni.Session
  alias Omni.Session.Manager.Tracker

  @type manager :: module()
  @type id :: Session.Store.session_id()

  @typedoc """
  Per-session entry returned by `list_open/1` and `subscribe/1`.
  """
  @type entry :: %{
          id: id(),
          title: String.t() | nil,
          status: :idle | :busy | :paused,
          pid: pid()
        }

  @manager_owned_opts [:store, :name, :new, :load]
  @default_idle_shutdown_after 300_000

  # ── use macro ──────────────────────────────────────────────────────

  defmacro __using__(_opts) do
    quote do
      def child_spec(opts),
        do: Omni.Session.Manager.child_spec([{:name, __MODULE__} | opts])

      def start_link(opts \\ []),
        do: Omni.Session.Manager.start_link([{:name, __MODULE__} | opts])

      def create(opts \\ []),
        do: Omni.Session.Manager.create(__MODULE__, opts)

      def open(id, opts \\ []),
        do: Omni.Session.Manager.open(__MODULE__, id, opts)

      def close(id),
        do: Omni.Session.Manager.close(__MODULE__, id)

      def delete(id),
        do: Omni.Session.Manager.delete(__MODULE__, id)

      def whereis(id),
        do: Omni.Session.Manager.whereis(__MODULE__, id)

      def list(opts \\ []),
        do: Omni.Session.Manager.list(__MODULE__, opts)

      def list_open,
        do: Omni.Session.Manager.list_open(__MODULE__)

      def subscribe,
        do: Omni.Session.Manager.subscribe(__MODULE__)

      def unsubscribe,
        do: Omni.Session.Manager.unsubscribe(__MODULE__)
    end
  end

  # ── Supervisor ─────────────────────────────────────────────────────

  @doc false
  def child_spec(opts) do
    name = fetch_name!(opts)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the Manager supervisor and its children.

  Required opt: `:name` (when called directly without `use`, pass the
  module name to register under).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    name = fetch_name!(opts)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    name = fetch_name!(opts)
    store = fetch_store!(opts)
    idle = fetch_idle_shutdown_after!(opts)

    :persistent_term.put(config_key(name), %{
      store: store,
      idle_shutdown_after: idle
    })

    children = [
      {Registry, keys: :unique, name: registry_name(name)},
      {DynamicSupervisor, name: dynsup_name(name), strategy: :one_for_one},
      {Tracker, name: tracker_name(name), manager: name, registry: registry_name(name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp fetch_name!(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) ->
        name

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a :name option " <>
                "(or invoke it via `use Omni.Session.Manager` on a module)"
    end
  end

  defp fetch_store!(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, {mod, cfg}} when is_atom(mod) and is_list(cfg) ->
        {mod, cfg}

      {:ok, other} ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :store must be a " <>
                "`{module, keyword()}` tuple, got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a :store option"
    end
  end

  defp fetch_idle_shutdown_after!(opts) do
    value = Keyword.get(opts, :idle_shutdown_after, @default_idle_shutdown_after)

    cond do
      is_nil(value) ->
        nil

      is_integer(value) and value >= 0 ->
        value

      true ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :idle_shutdown_after must be nil or a " <>
                "non-negative integer, got: #{inspect(value)}"
    end
  end

  defp registry_name(name), do: Module.concat(name, Registry)
  defp dynsup_name(name), do: Module.concat(name, DynamicSupervisor)
  defp tracker_name(name), do: Module.concat(name, "Tracker")
  defp config_key(name), do: {__MODULE__, name}
  defp config(manager), do: :persistent_term.get(config_key(manager))

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Starts a fresh session under this Manager.

  Options:
    * `:id` — explicit session id (binary). Auto-generated when omitted.
    * `:subscribe` — boolean, default `true`. Auto-subscribes the caller
      as `:controller`.
    * `:agent`, `:title`, `:subscribers`, `:idle_shutdown_after` — passed
      through to `Omni.Session.start_link/1`.

  Rejects Manager-owned opts (`:store`, `:name`, `:new`, `:load`) with
  `{:error, {:invalid_opt, key}}`. Returns `{:error, :already_exists}`
  when an explicit `:id` collides with a running session or one in the
  store.
  """
  @spec create(manager(), keyword()) ::
          {:ok, pid()}
          | {:error, :already_exists}
          | {:error, {:invalid_opt, atom()}}
          | {:error, term()}
  def create(manager, opts \\ []) when is_atom(manager) and is_list(opts) do
    caller = self()

    with :ok <- reject_manager_owned(opts),
         {:ok, id} <- resolve_create_id(opts) do
      session_opts =
        opts
        |> Keyword.delete(:id)
        |> Keyword.put(:new, id)

      case start_session(manager, id, session_opts, caller) do
        {:ok, pid} ->
          :ok = Tracker.add(tracker_name(manager), id, pid)
          {:ok, pid}

        {:error, reason} ->
          normalise_create_result({:error, reason})
      end
    end
  end

  @doc """
  Returns a pid for the session with the given id.

  The middle element of the return tuple tells you what happened:

    * `{:ok, :started, pid}` — session wasn't running; Manager loaded it
      from the store, and start-time opts (`:agent`, `:title`,
      `:idle_shutdown_after`, `:subscribers`) were applied.
    * `{:ok, :existing, pid}` — session was already running. Start-time
      opts are silently dropped (`:subscribe` still applies).

  Returns `{:error, :not_found}` when no session with the id exists in
  the store.

  The caller is auto-subscribed as `:controller` by default. Opt out
  with `subscribe: false`.
  """
  @spec open(manager(), id(), keyword()) ::
          {:ok, :started | :existing, pid()}
          | {:error, :not_found}
          | {:error, {:invalid_opt, atom()}}
          | {:error, term()}
  def open(manager, id, opts \\ [])
      when is_atom(manager) and is_binary(id) and is_list(opts) do
    caller = self()

    with :ok <- reject_manager_owned(opts) do
      session_opts = Keyword.put(opts, :load, id)

      case start_session(manager, id, session_opts, caller) do
        {:ok, pid} ->
          :ok = Tracker.add(tracker_name(manager), id, pid)
          {:ok, :started, pid}

        {:error, {:already_started, pid}} ->
          # Subscribe caller as controller before Tracker.add so the session
          # is pinned against idle-shutdown before the Tracker emits
          # :session_added — closes the timer race and the transient
          # no-controller window visible to Manager-level subscribers.
          :ok = subscribe_caller_on_existing(pid, caller, opts)
          :ok = Tracker.add(tracker_name(manager), id, pid)
          {:ok, :existing, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Stops a running session. Idempotent — returns `:ok` if the session is
  not running. The store is untouched.
  """
  @spec close(manager(), id()) :: :ok
  def close(manager, id) when is_atom(manager) and is_binary(id) do
    case whereis(manager, id) do
      nil ->
        :ok

      pid ->
        try do
          Session.stop(pid)
        catch
          :exit, _ -> :ok
        end

        :ok
    end
  end

  @doc """
  Stops the session if running, then deletes it from the store.

  Propagates the underlying `Omni.Session.Store.delete/3` error.
  """
  @spec delete(manager(), id()) :: :ok | {:error, term()}
  def delete(manager, id) when is_atom(manager) and is_binary(id) do
    :ok = close(manager, id)
    Session.Store.delete(config(manager).store, id)
  end

  @doc "Registry lookup — returns the session pid for `id`, or `nil`."
  @spec whereis(manager(), id()) :: pid() | nil
  def whereis(manager, id) when is_atom(manager) and is_binary(id) do
    case Registry.lookup(registry_name(manager), id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Lists sessions from the Manager's store.

  Pass-through to `Omni.Session.Store.list/2`. Honours adapter-level opts
  like `:limit` and `:offset`.
  """
  @spec list(manager(), keyword()) :: {:ok, [Session.Store.session_info()]}
  def list(manager, opts \\ []) when is_atom(manager) and is_list(opts) do
    Session.Store.list(config(manager).store, opts)
  end

  @doc """
  Returns the list of sessions currently running under this Manager.

  Each entry is a `%{id, title, status, pid}` map. Ordering is
  unspecified — callers sort client-side.

  Complements `list/2` (store-backed, may include sessions that are not
  running). The two are commonly composed to render an "all sessions
  with running indicator" view.
  """
  @spec list_open(manager()) :: [entry()]
  def list_open(manager) when is_atom(manager) do
    GenServer.call(tracker_name(manager), :list_open)
  end

  @doc """
  Subscribes the caller to Manager-level session events.

  Returns an atomic snapshot of currently-running sessions. After the
  call returns, the caller receives messages of shape:

      {:manager, manager_module, :session_added,   %{id, title, status, pid}}
      {:manager, manager_module, :session_status,  %{id, status}}
      {:manager, manager_module, :session_title,   %{id, title}}
      {:manager, manager_module, :session_removed, %{id}}

  The second element is the Manager module — the same atom the caller
  passed in — so a subscriber watching multiple Managers can route
  events by pattern-matching.

  Idempotent per pid: subscribing a second time returns a fresh
  snapshot without registering duplicate delivery.
  """
  @spec subscribe(manager()) :: {:ok, [entry()]}
  def subscribe(manager) when is_atom(manager) do
    GenServer.call(tracker_name(manager), {:subscribe, self()})
  end

  @doc "Unsubscribes the caller from Manager-level events."
  @spec unsubscribe(manager()) :: :ok
  def unsubscribe(manager) when is_atom(manager) do
    GenServer.call(tracker_name(manager), {:unsubscribe, self()})
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp reject_manager_owned(opts) do
    Enum.reduce_while(@manager_owned_opts, :ok, fn key, :ok ->
      if Keyword.has_key?(opts, key) do
        {:halt, {:error, {:invalid_opt, key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp resolve_create_id(opts) do
    case Keyword.get(opts, :id) do
      nil -> {:ok, generate_id()}
      id when is_binary(id) -> {:ok, id}
      _ -> {:error, {:invalid_opt, :id}}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # Spawns the Session under the DynamicSupervisor. Injects defaults
  # from Manager config, translates `:subscribe` into a `subscribers:`
  # list (the start_link caller is the DynamicSupervisor, not the real
  # caller — so Session's built-in `:subscribe` sugar doesn't apply),
  # and registers via `{:via, Registry, {reg, id}}` with
  # `restart: :temporary`.
  defp start_session(manager, id, caller_opts, caller) do
    cfg = config(manager)

    session_opts =
      caller_opts
      |> Keyword.put_new(:store, cfg.store)
      |> Keyword.put_new(:idle_shutdown_after, cfg.idle_shutdown_after)
      |> inject_caller_subscriber(caller)
      |> Keyword.put(:name, via_name(manager, id))

    child_spec = %{
      id: Session,
      start: {Session, :start_link, [session_opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(dynsup_name(manager), child_spec)
  end

  # The DynamicSupervisor is what actually calls `Session.start_link`, so
  # Session's own `subscribe: true` sugar (which uses `hd(callers)`) is
  # unusable here — it would subscribe the DynamicSupervisor and pin
  # every session against idle-shutdown. Strip `:subscribe` and always
  # list the real caller explicitly.
  defp inject_caller_subscriber(opts, caller) do
    {subscribe?, opts} = Keyword.pop(opts, :subscribe, true)

    if subscribe? do
      existing = List.wrap(Keyword.get(opts, :subscribers, []))
      Keyword.put(opts, :subscribers, [caller | existing])
    else
      opts
    end
  end

  defp subscribe_caller_on_existing(pid, caller, opts) do
    case Keyword.get(opts, :subscribe, true) do
      false ->
        :ok

      _ ->
        {:ok, _snap} = Session.subscribe(pid, caller, mode: :controller)
        :ok
    end
  end

  defp via_name(manager, id), do: {:via, Registry, {registry_name(manager), id}}

  defp normalise_create_result({:error, {:already_started, _pid}}),
    do: {:error, :already_exists}

  defp normalise_create_result({:error, :already_exists}),
    do: {:error, :already_exists}

  defp normalise_create_result({:error, reason}), do: {:error, reason}
end
