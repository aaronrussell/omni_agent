defmodule Omni.Agent.Manager do
  @moduledoc """
  Opt-in supervisor for registered, long-running agents.

  Manager is the single entry point for supervised, registry-backed
  agents. Add it to your application's supervision tree to enable
  supervised agents that are findable by id:

      # in MyApp.Application
      children = [
        Omni.Agent.Manager,
        # ...
      ]

  Manager wraps an internal `Registry` and `DynamicSupervisor` under
  known name atoms. Consumers don't reference those directly — the
  Manager module is the entire public surface.

  Ephemeral `Omni.Agent.start_link/1,2` agents work without Manager
  being started. Opt in only when you need supervision, registry
  lookup, or (later) idle-termination timers.

  ## Lifecycle

      {:ok, pid} = Omni.Agent.Manager.start_agent(
        store: Omni.Agent.Store.FileSystem,
        model: {:anthropic, "claude-sonnet-4-5-20250514"}
      )
      id = Omni.Agent.get_state(pid, :id)

      # ... later ...
      :ok = Omni.Agent.Manager.stop_agent(id)

  Each agent is registered under its id. `list_running/0` enumerates
  currently-registered ids; `lookup/1` resolves an id to its pid (or
  `nil`). Callers that want a boolean "is it running" compose as
  `lookup(id) != nil` or `id in list_running()` — no dedicated predicate.

  Supervised agents use `restart: :temporary` — crashed agents are not
  auto-restarted. Partial streaming state is lost on crash; persisted
  state survives. The next `start_agent` call loads fresh from the
  store.

  ## Id resolution

  Every supervised agent has an id (registration requires one).
  `start_agent/1,2` extracts or generates it from the opts that name
  an id — `:load`, `:new`, or `:id` — and registers the pid under that
  id in the Registry:

    * `:load "x"` present — load an existing persisted agent; id = `"x"`.
    * `:new "x"` present — create a new persisted agent with explicit id.
    * `:id "x"` present — supervised-ephemeral with explicit id.
    * `:store` present, no `:load` / `:new` / `:id` — persistent with
      auto-generated id; Manager generates it and injects as `:new id`.
    * None of the above — ephemeral with auto-generated id; Manager
      generates it and injects as `:id id`.

  Id generation is framework-level (`Omni.Agent.generate_id/0`) and
  independent of `:store`, so supervised-ephemeral agents (registered
  and findable by id without persistence) are a first-class mode
  alongside supervised-persistent ones.
  """

  use Supervisor

  @registry Omni.Agent.Registry
  @dynamic_supervisor Omni.Agent.DynamicSupervisor

  @doc """
  Starts the Manager under the consumer's supervision tree.

  Starts the internal Registry and DynamicSupervisor as children.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts a supervised agent without a callback module. See `start_agent/2`.
  """
  @spec start_agent(keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(opts) when is_list(opts), do: start_agent(nil, opts)

  @doc """
  Starts a supervised agent with an optional callback module.

  Passes `opts` through to `Omni.Agent.start_link/2` with two
  additions: `:name` is set to a `{:via, Registry, {...}}` tuple so
  the pid is registered under its id, and `:id` is injected if
  auto-generated.

  Returns:

    * `{:ok, pid}` on success
    * `{:error, {:already_started, pid}}` if an agent is already
      registered under the resolved id
    * any `{:error, reason}` returned by `Omni.Agent.start_link/2`
  """
  @spec start_agent(module() | nil, keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(module, opts) do
    {id, opts} = resolve_id(opts)
    opts = Keyword.put(opts, :name, {:via, Registry, {@registry, id}})

    spec = %{
      id: {Omni.Agent, id},
      start: {Omni.Agent, :start_link, [module, opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(@dynamic_supervisor, spec)
  end

  # Pick the id that will go into the Registry, and ensure opts name it
  # in a way the server will accept. :load / :new / :id from the caller
  # pass through; :store-alone gets a generated id injected as :new;
  # bare opts get a generated id injected as :id.
  defp resolve_id(opts) do
    cond do
      id = Keyword.get(opts, :load) -> {id, opts}
      id = Keyword.get(opts, :new) -> {id, opts}
      id = Keyword.get(opts, :id) -> {id, opts}
      Keyword.has_key?(opts, :store) -> generate_and_inject(opts, :new)
      true -> generate_and_inject(opts, :id)
    end
  end

  defp generate_and_inject(opts, key) do
    id = Omni.Agent.generate_id()
    {id, Keyword.put(opts, key, id)}
  end

  @doc """
  Stops the agent registered under `id` via graceful DynamicSupervisor
  termination.

  Idempotent — returns `:ok` whether or not an agent is running under
  `id`. `Omni.Agent` `terminate/2` callbacks run normally.
  """
  @spec stop_agent(String.t()) :: :ok
  def stop_agent(id) do
    with pid when is_pid(pid) <- lookup(id),
         :ok <- DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) do
      :ok
    else
      # lookup returned nil — agent isn't registered, nothing to do.
      nil -> :ok
      # terminate_child returned :not_found — the pid died between lookup
      # and termination (Registry cleanup is async). Treat as already stopped.
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Returns the pid of the agent registered under `id`, or `nil`.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns the ids of all currently-registered agents.
  """
  @spec list_running() :: [String.t()]
  def list_running do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
