defmodule Omni.Session.Store do
  @moduledoc """
  Persistence contract for `Omni.Session`.

  Defines the adapter behaviour that storage backends implement, and the
  dispatch functions that `Omni.Session` (and applications) call.

  A **store** is a `%Store{}` struct pairing the adapter module with its
  initialised config. Build one with `init/1`, which accepts several
  convenience forms:

      # Tuple — the most common form in config files
      {:ok, store} = Omni.Session.Store.init({Omni.Session.Store.FileSystem, base_dir: "/data/sessions"})

      # Bare module — equivalent to {mod, []}
      {:ok, store} = Omni.Session.Store.init(Omni.Session.Store.FileSystem)

      # Already-initialised struct — pass-through
      {:ok, ^store} = Omni.Session.Store.init(store)

  `Omni.Session.start_link/1` and `Omni.Session.Manager.start_link/1`
  both accept any of these forms as the `:store` option and call
  `init/1` internally, so callers rarely need to call it directly.

  ## Configuring a store once in an application

  The recommended path is to use `Omni.Session.Manager` with `otp_app:`,
  which reads the store from `Application.get_env/3` for you:

      defmodule MyApp.Sessions do
        use Omni.Session.Manager, otp_app: :my_app
      end

      # config/config.exs
      config :my_app, MyApp.Sessions,
        store: {Omni.Session.Store.FileSystem, base_dir: "/var/data/sessions"}

      # everywhere a session is needed
      MyApp.Sessions.create(agent: [...])
      MyApp.Sessions.delete("abc-123")

  When configuration varies per environment, override in `config/test.exs`
  (etc.) using the same key.

  ## Direct (non-Manager) usage

  When sessions are started outside a Manager, the application owns the
  store configuration. A module attribute is enough for static
  configuration:

      defmodule MyApp.Storage do
        @store {Omni.Session.Store.FileSystem, base_dir: "/var/data/sessions"}
        def store, do: @store
      end

      Omni.Session.start_link(store: MyApp.Storage.store(), new: id, agent: [...])

  For environment-specific configuration without a Manager, read the
  tuple from `Application.get_env/3` inside the wrapper.

  ## State categories

  Persisted state falls into two categories, owned by different write paths:

  | Category | Source | Callback | Trigger |
  |---|---|---|---|
  | Tree (nodes + path + cursors) | `%Omni.Session.Tree{}` | `save_tree` | Turn commits, navigation |
  | State map (model/system/opts/title) | Agent config + Session title | `save_state` | Agent `:state` events, `set_title/2` |

  The two write paths operate on disjoint keys. Adapters that persist
  both in a single file or row (the FileSystem reference does) can
  safely read-modify-write each side — it is key-splatting, not a
  semantic merge.

  ## Error model

  Store callbacks return `{:error, term()}` on failure; Session never
  halts on store errors. POSIX atoms (e.g. `:enoent`, `:eacces`) bubble
  up unwrapped from filesystem backends. Error reasons are
  adapter-specific.

  ## Implementing an adapter

  Implement `@behaviour Omni.Session.Store` and the seven callbacks:

  - `c:init/1`
  - `c:save_tree/4`
  - `c:save_state/4`
  - `c:load/3`
  - `c:list/2`
  - `c:delete/3`
  - `c:exists?/2`

  `c:init/1` receives the raw keyword config from the store tuple and
  returns `{:ok, config_state}` or `{:error, reason}`. The returned
  `config_state` is what all other callbacks receive as their first
  argument — it can be a keyword list, map, struct, or any term the
  adapter prefers.
  """

  alias Omni.Session.Tree

  defstruct [:module, :config]

  @typedoc "An initialised store — a struct pairing the adapter module with its config."
  @type t :: %__MODULE__{module: module(), config: term()}

  @typedoc "Application-assigned session identifier."
  @type session_id :: String.t()

  @typedoc """
  The prescribed Session-owned state map.

  A partial map is valid on `c:save_state/4` and on the `state_map`
  returned from `c:load/3`. Session merges the loaded subset against
  start options during hydration.
  """
  @type state_map :: %{
          optional(:model) => Omni.Model.ref(),
          optional(:system) => String.t() | nil,
          optional(:opts) => keyword(),
          optional(:title) => String.t() | nil
        }

  @typedoc "Summary info returned by `c:list/2`."
  @type session_info :: %{
          id: session_id(),
          title: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # ── Callbacks ───────────────────────────────────────────────────────

  @doc """
  Validate and prepare adapter config.

  Receives the raw keyword config from the store tuple. Returns
  `{:ok, config_state}` where `config_state` is passed as the first
  argument to all other callbacks, or `{:error, reason}` on invalid
  config.
  """
  @callback init(keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Persist the tree's nodes, active path, and cursors.

  `opts` may include `:new_node_ids` as an append hint — when present,
  the adapter may append only those nodes to its node log rather than
  rewriting the full set. When absent, the adapter should persist the
  full node set.

  Adapters manage their own `created_at` / `updated_at` timestamps.
  """
  @callback save_tree(config :: term(), session_id(), Tree.t(), keyword()) ::
              :ok | {:error, term()}

  @doc """
  Persist the Session-owned state map.

  Session always passes the full persistable subset it intends to retain
  under these keys — adapters use overwrite semantics. Keys not present
  in `state_map` should be left untouched by this call (they may have
  been written by a prior `c:save_tree/4`).
  """
  @callback save_state(config :: term(), session_id(), state_map(), keyword()) ::
              :ok | {:error, term()}

  @doc """
  Load a session by id.

  Returns `{:ok, tree, state_map}` on success, or `{:error, :not_found}`
  when no session exists for the id. `state_map` may contain only a
  subset of keys if the session has never had some values persisted.
  """
  @callback load(config :: term(), session_id(), keyword()) ::
              {:ok, Tree.t(), state_map()} | {:error, :not_found}

  @doc """
  List session summaries ordered by `updated_at` descending.

  Adapters **must** honour the following `opts`:

    * `:limit` — maximum number of results (unlimited if absent).
    * `:offset` — number of results to skip (defaults to `0`).

  Other `opts` are adapter-specific; undefined options are ignored.
  """
  @callback list(config :: term(), keyword()) :: {:ok, [session_info()]}

  @doc "Delete a session and all its persisted state."
  @callback delete(config :: term(), session_id(), keyword()) ::
              :ok | {:error, term()}

  @doc """
  Returns `true` if `id` has persisted state in the adapter.

  Used by `Omni.Session` to detect duplicate-id collisions on
  `start_link(new: binary_id)`. Adapter errors should surface as
  `false` — the caller treats "unsure" and "not present" identically.
  """
  @callback exists?(config :: term(), session_id()) :: boolean()

  # ── Init ────────────────────────────────────────────────────────────

  @doc """
  Initialise a store from one of several input forms.

  Accepts a `{module, keyword}` tuple, a bare module atom (equivalent
  to `{module, []}`), or an already-initialised `%Store{}` struct
  (pass-through). Returns `{:ok, %Store{}}` or `{:error, reason}`.

  Called automatically by `Omni.Session.start_link/1` and
  `Omni.Session.Manager.start_link/1` — most callers don't need to
  invoke this directly.
  """
  @spec init(t() | {module(), keyword()} | module()) :: {:ok, t()} | {:error, term()}
  def init(%__MODULE__{} = store), do: {:ok, store}

  def init({mod, cfg}) when is_atom(mod) and is_list(cfg) do
    call_adapter_init(mod, cfg)
  end

  def init(mod) when is_atom(mod) and not is_nil(mod) do
    call_adapter_init(mod, [])
  end

  def init(other), do: {:error, {:invalid_store, other}}

  defp call_adapter_init(mod, cfg) do
    Code.ensure_loaded(mod)

    if function_exported?(mod, :init, 1) do
      case mod.init(cfg) do
        {:ok, config_state} -> {:ok, %__MODULE__{module: mod, config: config_state}}
        {:error, _} = error -> error
      end
    else
      {:error, {:not_a_store_adapter, mod}}
    end
  end

  # ── Dispatch ────────────────────────────────────────────────────────

  @doc "Persist the tree via the store's adapter."
  @spec save_tree(t(), session_id(), Tree.t(), keyword()) :: :ok | {:error, term()}
  def save_tree(%__MODULE__{module: mod, config: cfg}, id, %Tree{} = tree, opts \\ []),
    do: mod.save_tree(cfg, id, tree, opts)

  @doc "Persist the state map via the store's adapter."
  @spec save_state(t(), session_id(), state_map(), keyword()) :: :ok | {:error, term()}
  def save_state(%__MODULE__{module: mod, config: cfg}, id, state, opts \\ []) when is_map(state),
    do: mod.save_state(cfg, id, state, opts)

  @doc "Load a session via the store's adapter."
  @spec load(t(), session_id(), keyword()) ::
          {:ok, Tree.t(), state_map()} | {:error, :not_found}
  def load(%__MODULE__{module: mod, config: cfg}, id, opts \\ []),
    do: mod.load(cfg, id, opts)

  @doc "List session summaries via the store's adapter."
  @spec list(t(), keyword()) :: {:ok, [session_info()]}
  def list(%__MODULE__{module: mod, config: cfg}, opts \\ []),
    do: mod.list(cfg, opts)

  @doc "Delete a session via the store's adapter."
  @spec delete(t(), session_id(), keyword()) :: :ok | {:error, term()}
  def delete(%__MODULE__{module: mod, config: cfg}, id, opts \\ []),
    do: mod.delete(cfg, id, opts)

  @doc "Check whether the store holds persisted state for `id`."
  @spec exists?(t(), session_id()) :: boolean()
  def exists?(%__MODULE__{module: mod, config: cfg}, id),
    do: mod.exists?(cfg, id)
end
