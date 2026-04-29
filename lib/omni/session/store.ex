defmodule Omni.Session.Store do
  @moduledoc """
  Persistence contract for `Omni.Session`.

  Defines the adapter behaviour that storage backends implement, and the
  dispatch functions that `Omni.Session` (and applications) call.

  A **store** is a `{module, keyword()}` tuple pairing the adapter module
  with its config. This is the canonical shape everywhere: users write it
  at `Session.start_link(store: ...)` time, Session threads it through
  internally, and applications stash it wherever they like.

      store = {Omni.Session.Store.FileSystem, base_path: "/data/sessions"}

      Omni.Session.start_link(store: store, new: "abc", agent: [...])
      Omni.Session.Store.delete(store, "abc")

  ## Configuring a store once in an application

  The recommended path is to use `Omni.Session.Manager` with `otp_app:`,
  which reads the store from `Application.get_env/3` for you:

      defmodule MyApp.Sessions do
        use Omni.Session.Manager, otp_app: :my_app
      end

      # config/config.exs
      config :my_app, MyApp.Sessions,
        store: {Omni.Session.Store.FileSystem, base_path: "priv/sessions", otp_app: :my_app}

      # everywhere a session is needed
      MyApp.Sessions.create(agent: [...])
      MyApp.Sessions.delete("abc-123")

  When configuration varies per environment, override in `config/test.exs`
  (etc.) using the same key.

  ## Direct (non-Manager) usage

  When sessions are started outside a Manager, the application owns the
  store tuple. A module attribute is enough for static configuration:

      defmodule MyApp.Storage do
        @store {Omni.Session.Store.FileSystem, base_path: "/var/data/sessions"}
        def store, do: @store
      end

      Omni.Session.start_link(store: MyApp.Storage.store(), new: id, agent: [...])
      Omni.Session.Store.delete(MyApp.Storage.store(), id)

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

  Implement `@behaviour Omni.Session.Store` and the six callbacks:

  - `c:save_tree/4`
  - `c:save_state/4`
  - `c:load/3`
  - `c:list/2`
  - `c:delete/3`
  - `c:exists?/2`

  Configuration arrives as a `keyword()` (the second element of the
  store tuple). Adapters are free to validate or destructure it as
  they prefer.
  """

  alias Omni.Session.Tree

  @typedoc "A store is `{adapter_module, config}` — a tagged pair Session threads through calls."
  @type t :: {module(), keyword()}

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

  # Dispatch

  @doc "Persist the tree via the store's adapter."
  @spec save_tree(t(), session_id(), Tree.t(), keyword()) :: :ok | {:error, term()}
  def save_tree({mod, cfg}, id, %Tree{} = tree, opts \\ []),
    do: mod.save_tree(cfg, id, tree, opts)

  @doc "Persist the state map via the store's adapter."
  @spec save_state(t(), session_id(), state_map(), keyword()) :: :ok | {:error, term()}
  def save_state({mod, cfg}, id, state, opts \\ []) when is_map(state),
    do: mod.save_state(cfg, id, state, opts)

  @doc "Load a session via the store's adapter."
  @spec load(t(), session_id(), keyword()) ::
          {:ok, Tree.t(), state_map()} | {:error, :not_found}
  def load({mod, cfg}, id, opts \\ []),
    do: mod.load(cfg, id, opts)

  @doc "List session summaries via the store's adapter."
  @spec list(t(), keyword()) :: {:ok, [session_info()]}
  def list({mod, cfg}, opts \\ []),
    do: mod.list(cfg, opts)

  @doc "Delete a session via the store's adapter."
  @spec delete(t(), session_id(), keyword()) :: :ok | {:error, term()}
  def delete({mod, cfg}, id, opts \\ []),
    do: mod.delete(cfg, id, opts)

  @doc "Check whether the store holds persisted state for `id`."
  @spec exists?(t(), session_id()) :: boolean()
  def exists?({mod, cfg}, id),
    do: mod.exists?(cfg, id)
end
