defmodule Omni.Session.Snapshot do
  @moduledoc """
  A consistent view of an `Omni.Session` at a point in time.

  Returned by `Omni.Session.get_snapshot/1` and `Omni.Session.subscribe/1,2`.

  Fields:

  - `:id` — the session's identifier
  - `:title` — the session's human-friendly title, or `nil`
  - `:tree` — the `%Omni.Session.Tree{}` of committed conversation
    history at the snapshot instant
  - `:agent` — an `%Omni.Agent.Snapshot{}` capturing the wrapped
    agent's state, in-flight pending messages, and currently-streaming
    partial message

  To compose the complete view of everything the session knows right
  now:

      committed = Omni.Session.Tree.messages(snapshot.tree)
      in_flight = snapshot.agent.pending ++ List.wrap(snapshot.agent.partial)
      committed ++ in_flight

  `snapshot.agent.state.messages` mirrors `Tree.messages(snapshot.tree)`
  — treat the tree as the source of truth for committed structure;
  `agent.pending` / `agent.partial` carry the streaming tail.
  """

  alias Omni.Agent
  alias Omni.Session.Tree

  @typedoc "A Session snapshot."
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          tree: Tree.t(),
          agent: Agent.Snapshot.t()
        }

  defstruct [:id, :title, :tree, :agent]
end
