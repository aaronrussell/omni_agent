defmodule Omni.Agent.Store do
  @moduledoc """
  Behaviour for persistence adapters.

  An agent becomes persistent when its caller passes a `:store` option at
  start time. The `:store` value is an adapter module implementing this
  behaviour — there is no global configuration. Ephemeral agents (no
  `:store`) don't persist anything.

  This module is behaviour-only — it defines the callbacks adapters must
  implement plus the shared `state_data` and `summary` types. Callers use
  the adapter module directly:

      {:ok, summaries} = Omni.Agent.Store.FileSystem.list([])
      :ok              = Omni.Agent.Store.FileSystem.delete(id, [])

  `generate_id/0`, `save_tree/3`, `save_state/3`, and `load/2` are invoked
  by the agent server during init and write-through; they are part of the
  behaviour for adapter authors but rarely called from application code.

  ## Deleting a live agent's session

  A session with a live Manager-supervised agent should be stopped before
  its persisted data is removed. This is a two-call pattern — the caller
  owns both steps:

      :ok = Omni.Agent.Manager.stop_agent(id)
      :ok = Omni.Agent.Store.FileSystem.delete(id, [])

  A single-call "stop and delete" API was considered and rejected: it
  would either have to live on `Store` (forcing the caller to pass the
  adapter module back in as an option — pure indirection over calling the
  adapter directly) or on `Manager` (forcing the same dance with the
  adapter). Until a cleaner shape emerges, the cross-cut stays caller-owned.

  A caller that skips `stop_agent/1` still works: the supervised pid's
  idle timer eventually terminates it, and any write-through attempts
  after deletion surface as `:store` error events rather than crashing
  the agent.

  ## Timestamps

  `created_at` and `updated_at` are managed by the adapter, not the
  caller. The adapter sets `created_at` on first write and `updated_at`
  on every write.

  ## `state_data` shape

  Loaded and saved state excludes runtime-only fields (`tools`, callback
  module, subscribers, `:private`, `:status`, `:step`). The model is
  persisted as a `{provider_id, model_id}` reference and re-resolved on
  load.
  """

  alias Omni.Model
  alias Omni.Agent.Tree

  @typedoc "Agent identifier (adapter-defined shape)."
  @type id :: String.t()

  @typedoc "Adapter module implementing `Omni.Agent.Store`."
  @type adapter :: module()

  @typedoc "The serialisable subset of agent state."
  @type state_data :: %{
          tree: Tree.t(),
          model: Model.ref(),
          system: String.t() | nil,
          opts: keyword(),
          meta: map()
        }

  @typedoc "Summary returned by `list/1`."
  @type summary :: %{
          id: id(),
          title: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Generates a fresh agent identifier.

  Called by the agent server (or by `Omni.Agent.Manager`) when a
  persistent agent is started without an explicit id.
  """
  @callback generate_id() :: id()

  @doc """
  Persists the conversation tree for `id`.

  Accepts `:new_node_ids` in opts as an optimisation hint. When present,
  the adapter may append only those nodes rather than rewriting the full
  node set.
  """
  @callback save_tree(id(), Tree.t(), keyword()) :: :ok | {:error, term()}

  @doc """
  Persists the configuration subset of agent state for `id`.

  Called whenever a persisted field (`:model`, `:system`, `:opts`,
  `:meta`) changes, and on first init when a store is attached. Tree
  data is handled separately via `save_tree/3`.
  """
  @callback save_state(id(), state_data(), keyword()) :: :ok | {:error, term()}

  @doc """
  Loads the persisted state for `id`, or returns `{:error, :not_found}`.
  """
  @callback load(id(), keyword()) :: {:ok, state_data()} | {:error, :not_found}

  @doc """
  Lists stored agents, sorted by `:updated_at` descending.

  ## Options

    * `:limit` — maximum number of summaries to return. Unlimited by default.
    * `:offset` — number of summaries to skip from the start. Defaults to 0.
  """
  @callback list(keyword()) :: {:ok, [summary()]}

  @doc "Deletes the stored data for `id`."
  @callback delete(id(), keyword()) :: :ok | {:error, term()}
end
