defmodule Omni.Agent.Snapshot do
  @moduledoc """
  A point-in-time view of an agent, returned by `Omni.Agent.subscribe/1`.

  Late subscribers use the snapshot to render current state; subsequent events
  update their local cache incrementally. The snapshot mirrors the public parts
  of `%Omni.Agent.State{}` plus two fields that only make sense for subscribers:

    * `:partial_message` — the in-flight assistant message (content blocks
      accumulated from streaming deltas). `nil` unless the agent is currently
      streaming a step.
    * `:paused` — `{reason, tool_use}` when the agent is awaiting a tool
      decision via `resume/2`; `nil` otherwise. Same shape as the `:pause`
      event data, so subscribers can reuse the same pattern match.

  The `:private` field from state is not included — it is for callback-local
  runtime data and is never broadcast.
  """

  alias Omni.{Message, Model, Tool}
  alias Omni.Content.ToolUse

  @typedoc "A content block (Text, Thinking, ToolUse, etc.) as emitted by streaming events."
  @type content_block :: struct()

  @typedoc "A point-in-time snapshot of agent state."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: Model.t(),
          system: String.t() | nil,
          tools: [Tool.t()],
          tree: [Message.t()],
          opts: keyword(),
          meta: map(),
          status: :idle | :running | :paused,
          step: non_neg_integer(),
          partial_message: [content_block] | nil,
          paused: {reason :: term(), ToolUse.t()} | nil
        }

  defstruct [
    :id,
    :model,
    :system,
    tools: [],
    tree: [],
    opts: [],
    meta: %{},
    status: :idle,
    step: 0,
    partial_message: nil,
    paused: nil
  ]
end
