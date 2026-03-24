defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, process refs)
  is managed separately and not exposed to callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, changeable via `set_state/2,3`:

    * `:model` — the `%Model{}` this agent is using
    * `:context` — `%Context{}` containing the system prompt, messages, and tools.
      Only reflects committed messages from completed turns — in-progress turn
      messages are held internally until the turn completes
    * `:opts` — agent-level default inference options (keyword list), passed to
      `stream_text` each step

  **Session** — change during operation:

    * `:meta` — user metadata map (title, tags, custom domain data). Set initial
      values via `:meta` start option, update via `set_state/2,3`
    * `:private` — runtime state (PIDs, ETS refs, closures). Not persisted.
      Set initial values in `init/1`, update in any callback via
      `%{state | private: ...}`
    * `:status` — `:idle`, `:running`, or `:paused`
    * `:step` — current step counter within the active turn. Resets to `0`
      when a new turn begins. Useful for step-based policies in callbacks
      (e.g. rejecting tools after a threshold)
  """

  alias Omni.{Context, Model}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          model: Model.t(),
          context: Context.t(),
          opts: keyword(),
          meta: map(),
          private: map(),
          status: :idle | :running | :paused,
          step: non_neg_integer()
        }

  defstruct [
    :model,
    :opts,
    context: %Context{},
    meta: %{},
    private: %{},
    status: :idle,
    step: 0
  ]
end
