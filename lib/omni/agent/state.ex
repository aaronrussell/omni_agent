defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, subscriber
  set, streaming accumulator) is managed separately and not exposed to
  callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, changeable via `set_state/2,3`:

    * `:model` — the `%Model{}` this agent is using
    * `:system` — optional system prompt string
    * `:tools` — list of `%Tool{}` structs available to the model
    * `:tree` — the conversation's committed messages. In Phase 1 this is a
      flat `[%Message{}]`; a later phase replaces it with a branching tree
      struct. Only reflects committed messages from completed turns —
      in-progress turn messages are held internally until the turn completes
    * `:opts` — agent-level default inference options (keyword list), passed
      to `stream_text` each step

  **Session** — change during operation:

    * `:id` — agent identifier. `nil` for ephemeral agents (the Phase 1
      default); populated by the store when persistence is configured in a
      later phase
    * `:meta` — user metadata map (title, tags, custom domain data). Set
      initial values via `:meta` start option, update via `set_state/2,3`
    * `:private` — runtime state (PIDs, ETS refs, closures). Not broadcast to
      subscribers and never persisted. Set initial values in `init/1`, update
      in any callback via `%{state | private: ...}`
    * `:status` — `:idle`, `:running`, or `:paused`
    * `:step` — current step counter within the active turn. Resets to `0`
      when a new turn begins. Useful for step-based policies in callbacks
      (e.g. rejecting tools after a threshold)
  """

  alias Omni.{Message, Model, Tool}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          model: Model.t(),
          system: String.t() | nil,
          tools: [Tool.t()],
          tree: [Message.t()],
          opts: keyword(),
          meta: map(),
          private: map(),
          status: :idle | :running | :paused,
          step: non_neg_integer()
        }

  defstruct [
    :id,
    :model,
    :system,
    tools: [],
    tree: [],
    opts: [],
    meta: %{},
    private: %{},
    status: :idle,
    step: 0
  ]
end
