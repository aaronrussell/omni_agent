defmodule Omni.Agent.State do
  @moduledoc """
  The public state passed to all `Omni.Agent` callbacks.

  Internal server machinery (task tracking, tool decision state, process refs)
  is managed separately and not exposed to callbacks.

  Fields fall into two groups:

  **Configuration** — set at startup, changeable via `set_state/2,3`:

  - `:model` — the `%Model{}` this agent is using
  - `:system` — system prompt string, or `nil`
  - `:messages` — committed message history. Only changes at turn boundaries
    or via `set_state(:messages, ...)`; in-progress turn messages are held
    internally until the turn completes
  - `:tools` — list of `%Tool{}` available to the model
  - `:opts` — agent-level default inference options (keyword list), passed to
    `stream_text` each step

  **Runtime** — change during operation:

  - `:private` — runtime state (PIDs, ETS refs, closures). Not persisted.
    Set initial values via the `:private` start option or in `init/1`,
    update in any callback via `%{state | private: ...}`. Not settable via
    `set_state/2,3`. The `:omni` key is reserved — when running under
    `Omni.Session`, the session writes `private[:omni] = %{session_id:
    ..., session_pid: ...}` before `init/1` runs and overwrites any
    user-supplied value. Use any other key freely
  - `:status` — `:idle`, `:busy`, or `:paused`
  - `:step` — current step counter within the active turn. Resets to `0`
    when a new turn begins. Useful for step-based policies in callbacks
    (e.g. rejecting tools after a threshold)
  """

  alias Omni.{Content, Message, Model, Tool}

  @typedoc "The public agent state passed to all callbacks."
  @type t :: %__MODULE__{
          model: Model.t(),
          system: String.t() | nil,
          messages: [Message.t()],
          tools: [Tool.t()],
          opts: keyword(),
          private: map(),
          status: :idle | :busy | :paused,
          step: non_neg_integer()
        }

  defstruct [
    :model,
    :system,
    :opts,
    messages: [],
    tools: [],
    private: %{},
    status: :idle,
    step: 0
  ]

  @doc """
  Validates that a message list is safe to sit idle in `state.messages`.

  Returns `:ok` if the list is empty, or if its last message has
  `role: :assistant` and contains no `%Omni.Content.ToolUse{}` blocks.
  Otherwise returns `{:error, :invalid_messages}`.

  This is the invariant enforced at `set_state(:messages, ...)` and on the
  state returned from `init/1`. It does not perform deep validation of
  interior messages.
  """
  @spec validate_messages([Message.t()]) :: :ok | {:error, :invalid_messages}
  def validate_messages([]), do: :ok

  def validate_messages(messages) when is_list(messages) do
    case List.last(messages) do
      %Message{role: :assistant, content: content} ->
        if Enum.any?(content, &match?(%Content.ToolUse{}, &1)) do
          {:error, :invalid_messages}
        else
          :ok
        end

      _ ->
        {:error, :invalid_messages}
    end
  end

  def validate_messages(_), do: {:error, :invalid_messages}
end
