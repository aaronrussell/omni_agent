defmodule Omni.Agent.Snapshot do
  @moduledoc """
  A consistent view of an `Omni.Agent` at a point in time.

  Returned by `Omni.Agent.get_snapshot/1` and `Omni.Agent.subscribe/1,2`.
  Consumers who want the complete set of messages the agent knows about
  right now compose:

      state.messages ++ pending ++ List.wrap(partial)

  Fields:

    * `:state` — the public `%Omni.Agent.State{}` (committed history,
      model, tools, status, ...)
    * `:pending` — messages accumulated during the in-flight turn,
      not yet committed to `state.messages`
    * `:partial` — the assistant message currently streaming, or `nil`
      if no step is in progress
  """

  alias Omni.Agent.State
  alias Omni.Message

  @typedoc "An Agent snapshot."
  @type t :: %__MODULE__{
          state: State.t(),
          pending: [Message.t()],
          partial: Message.t() | nil
        }

  defstruct [:state, pending: [], partial: nil]
end
