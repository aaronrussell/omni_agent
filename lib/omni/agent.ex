defmodule Omni.Agent do
  @moduledoc """
  Stateful LLM agents for Elixir. Multi-turn conversations with lifecycle
  callbacks, tool approval, and steering.

  An agent holds a model, a context (system prompt, messages, tools), and
  user-defined state. The outside world sends prompts in; the agent streams
  events back. Between turns, lifecycle callbacks control whether the agent
  continues, stops, or pauses for human approval.

  Use an agent instead of the stateless `generate_text`/`stream_text` API when
  you need the process to own the conversation — managing context, executing
  tools with approval gates, and looping autonomously across multiple turns.

  ## Quick start

  Start an agent without a callback module for simple conversations:

      {:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-sonnet-4-5-20250514"})
      :ok = Omni.Agent.prompt(agent, "Hello!")

      # Events arrive as process messages
      receive do
        {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
        {:agent, ^agent, :turn, {:stop, response}} -> IO.puts("\\nDone!")
      end

  The first `prompt/3` call automatically sets the caller as the event
  listener. Call `listen/2` to set a different process.

  ## Custom agents

  Define a module with `use Omni.Agent` to customize behaviour through
  lifecycle callbacks. All callbacks are optional with sensible defaults.

  `init/1` receives the fully-resolved initial `%State{}` and returns a
  possibly-modified state. Use it to bake in defaults (system prompt, tools)
  or to customize the state based on per-invocation input passed via
  `:private`:

      defmodule GreeterAgent do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          system = "You are a helpful assistant. The user's name is \#{state.private.user}."
          {:ok, %{state | system: system}}
        end

        @impl Omni.Agent
        def handle_turn(%{stop_reason: :length}, state) do
          {:continue, "Continue where you left off.", state}
        end

        def handle_turn(_response, state), do: {:stop, state}
      end

      {:ok, agent} = GreeterAgent.start_link(
        model: {:anthropic, "claude-sonnet-4-5-20250514"},
        private: %{user: "Alice"}
      )

  For static defaults — system prompt, tools, inference opts — set them in
  `init/1` directly rather than overriding `start_link/1`:

      defmodule ResearchAgent do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          state = %{state |
            system: "You are a research assistant.",
            tools: [SearchTool.new(), FetchTool.new()]
          }
          {:ok, state}
        end
      end

      {:ok, agent} = ResearchAgent.start_link(
        model: {:anthropic, "claude-sonnet-4-5-20250514"}
      )

  ## Start options

  Options for `start_link/1` and `start_link/2`:

    * `:model` (required) — `{provider_id, model_id}` tuple or `%Model{}`
    * `:system` — system prompt string
    * `:messages` — initial `%Message{}` list. Must be empty or end with an
      `:assistant` message containing no `%ToolUse{}` blocks
    * `:tools` — list of `%Tool{}` structs
    * `:private` — initial private map (runtime state visible in callbacks
      via `state.private`)
    * `:listener` — pid to receive events (defaults to first `prompt/3` caller)
    * `:tool_timeout` — per-tool execution timeout in ms (default `5_000`)
    * `:opts` — inference options passed to `stream_text` each step
      (`:temperature`, `:max_tokens`, `:max_steps`, etc.)
    * `:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug` —
      standard GenServer options

  ## Events

  The listener receives `{:agent, pid, type, data}` messages. There are two
  categories:

  **Streaming events** — forwarded from each LLM response as it arrives:

      {:agent, pid, :text_start,     %{index: 0}}
      {:agent, pid, :text_delta,     %{index: 0, delta: "Hello"}}
      {:agent, pid, :text_end,       %{index: 0, content: %Text{}}}
      {:agent, pid, :thinking_start, %{index: 0}}
      {:agent, pid, :thinking_delta, %{index: 0, delta: "..."}}
      {:agent, pid, :thinking_end,   %{index: 0, content: %Thinking{}}}
      {:agent, pid, :tool_use_start, %{index: 1, id: "call_1", name: "search"}}
      {:agent, pid, :tool_use_delta, %{index: 1, delta: "{\\"q\\":"}}
      {:agent, pid, :tool_use_end,   %{index: 1, content: %ToolUse{}}}

  **Agent-level events** — emitted by the agent at lifecycle boundaries:

      {:agent, pid, :message,     %Message{}}                        # message appended to pending
      {:agent, pid, :tool_result, %ToolResult{}}                     # tool executed, result available
      {:agent, pid, :step,        %Response{}}                       # step complete, per-step response
      {:agent, pid, :turn,        {:continue, %Response{}}}          # segment committed, turn continues
      {:agent, pid, :turn,        {:stop, %Response{}}}              # turn ended, pending committed, idle
      {:agent, pid, :pause,       {reason, %ToolUse{}}}              # waiting for tool decision
      {:agent, pid, :retry,       reason}                            # non-terminal error, agent retrying
      {:agent, pid, :error,       reason}                            # terminal error, agent goes idle
      {:agent, pid, :cancelled,   %Response{stop_reason: :cancelled}} # cancel/1 invoked; pending discarded
      {:agent, pid, :state,       %State{}}                          # set_state mutation applied

  `:message` fires each time a message is appended to the in-flight
  pending queue — the initial user message, each assistant response after
  streaming completes, the tool-result user message after execution, and
  the continuation user message after `{:continue, _, _}`. It arrives
  after all streaming deltas for that message and before the next
  lifecycle event.

  `:step` fires after each LLM request-response completes. The response's
  `messages` field contains only the messages added in that step — the
  assistant response, plus the preceding tool-result user message on
  steps that followed tool execution.

  `:turn` fires at segment boundaries and commits the segment's pending
  messages to `state.messages`. `{:continue, response}` means the turn
  keeps going — a continuation user message is appended next.
  `{:stop, response}` means the turn is done and the agent is idle. Each
  `:turn` event's response carries only that segment's committed
  messages, not the whole turn's.

  `:cancelled` fires after `cancel/1` with `stop_reason: :cancelled` —
  pending messages are discarded (`state.messages` unchanged). `:error`
  fires after `handle_error/2` returns `{:stop, state}` — pending
  messages are discarded and the agent goes idle. `:state` fires after a
  successful `set_state/2,3` call with the full new `%State{}`. A simple
  chatbot (one step per prompt) sees `:message(user) → :message(assistant)
  → :step → :turn {:stop, _}`.

  ## Tools and the agent loop

  The agent manages its own tool execution loop, separate from the stateless
  loop used by `generate_text`/`stream_text`. This enables per-tool approval
  gates and pause/resume — capabilities that the stateless loop cannot support.

  When the model responds with tool use blocks, the agent processes them in
  two phases:

  1. **Decision phase** — `handle_tool_use/2` is called sequentially for each
     tool use. Return `{:execute, state}` to approve, `{:reject, reason, state}`
     to send an error result, `{:result, result, state}` to provide a result
     directly, or `{:pause, reason, state}` to wait for external input via
     `resume/2`.

  2. **Execution phase** — approved tools run in parallel. Results (from
     execution, rejection, and direct provision) are passed to
     `handle_tool_result/2`, then sent back to the model as a user message.
     The agent spawns the next LLM request automatically.

  If a tool has no handler and falls through `handle_tool_use/2` without
  being intercepted (via `{:result, ...}` or `{:pause, ...}`), the agent
  stops the turn — `handle_turn/2` fires with `stop_reason: :tool_use`.

  ## Pause and resume

  When `handle_tool_use/2` returns `{:pause, reason, state}`, the agent
  pauses and sends `{:agent, pid, :pause, {reason, %ToolUse{}}}` to the
  listener. The `reason` is an app-defined term (e.g., `:authorize`,
  `:ui_input`) that tags why the agent paused. The caller inspects the
  tool use and resumes:

      Agent.resume(agent, :execute)              # execute the tool
      Agent.resume(agent, {:reject, "Denied"})   # reject with error result
      Agent.resume(agent, {:result, result})      # provide a result directly

  After resuming, the agent continues processing remaining tool decisions.

  ## Prompt queuing

  Calling `prompt/3` while the agent is running or paused stages the content
  for the next turn boundary. When the current step sequence completes:

    * `handle_turn/2` fires as normal (for bookkeeping, state updates)
    * The staged prompt overrides `handle_turn`'s decision — the agent
      continues with the staged content regardless of whether the callback
      returned `{:stop, state}` or `{:continue, ...}`

  This enables steering an autonomous agent mid-run:

      :ok = Agent.prompt(agent, "Stop what you're doing, focus on X instead")

  Calling `prompt/3` again replaces the staged prompt (last-one-wins).

  ## Autonomous agents

  The difference between a chatbot (one step per prompt) and an autonomous
  agent (works until done) is entirely in the callbacks. A completion tool
  with a trivial handler serves as the signal — the agent loops until the
  model calls it:

      defmodule ResearchAgent do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          state = %{state |
            system: "You are a research assistant. Use your tools to research, " <>
                    "then call task_complete with your findings.",
            tools: [SearchTool.new(), FetchTool.new(), task_complete()],
            opts: Keyword.put(state.opts, :max_steps, 30)
          }
          {:ok, state}
        end

        @impl Omni.Agent
        def handle_turn(%{stop_reason: :length}, state) do
          {:continue, "Continue where you left off.", state}
        end

        def handle_turn(response, state) do
          if completion_tool_called?(response) do
            {:stop, state}
          else
            {:continue, "Continue working. Call task_complete when finished.", state}
          end
        end

        defp task_complete do
          Omni.tool(
            name: "task_complete",
            description: "Call when the task is fully complete.",
            input_schema: Omni.Schema.object(
              %{result: Omni.Schema.string(description: "Summary of what was accomplished")},
              required: [:result]
            ),
            handler: fn _input -> "OK" end
          )
        end

        defp completion_tool_called?(response) do
          Enum.any?(response.messages, fn message ->
            Enum.any?(message.content, fn
              %Omni.Content.ToolUse{name: "task_complete"} -> true
              _ -> false
            end)
          end)
        end
      end

  ## Steps, turns, and max_steps

  The agent loop has two levels:

    * **Step** — a single LLM request-response cycle. If the model calls tools,
      the agent handles them and makes another request. Each request is one step.
    * **Turn** — starts with `prompt/3`, ends with `{:stop, response}`.
      A turn may contain multiple steps. `handle_turn/2` fires when the model
      responds without executable tools. If it returns `{:continue, ...}`, the
      agent keeps working within the same turn.

  Each step emits a `:step` event with the per-step response. Turn boundaries
  emit `:turn` events. A turn with continuation looks like this:

      turn
        step 1 → :step → tool_use → step 2 → :step → tool_use
          → step 3 → :step → handle_turn
          → {:continue, "keep going"} → :turn {:continue, _}
        step 4 → :step → handle_turn
          → {:stop, state} → :turn {:stop, _}

  `:max_steps` (default `:infinity`) caps the total number of LLM requests
  across the turn. Set it in `:opts` at startup or override per-prompt via
  `prompt/3`:

      Agent.prompt(agent, "Do exhaustive research", max_steps: 50)

  The step counter (`state.step`) is visible in all callbacks.

  ## LiveView integration

  Agent events map naturally to `handle_info/2`:

      def handle_event("submit", %{"prompt" => text}, socket) do
        :ok = Agent.prompt(socket.assigns.agent, text)
        {:noreply, socket}
      end

      def handle_info({:agent, _pid, :text_delta, %{delta: text}}, socket) do
        {:noreply, stream_insert(socket, :chunks, %{text: text})}
      end

      def handle_info({:agent, _pid, :turn, {:stop, _response}}, socket) do
        {:noreply, assign(socket, :status, :complete)}
      end

      def handle_info({:agent, _pid, :error, reason}, socket) do
        {:noreply, put_flash(socket, :error, "Agent error: \#{inspect(reason)}")}
      end
  """

  alias Omni.Agent.State
  alias Omni.Content.{ToolResult, ToolUse}
  alias Omni.Response

  @doc """
  Called when the agent starts.

  Receives the fully-resolved initial `%State{}` (start options merged, model
  resolved) and returns a possibly-modified state. The callback can tweak any
  field — inject `:private`, preload `:messages`, swap the `:system` prompt,
  add `:tools`.

  The returned state is validated against the `:messages` invariant (empty or
  ending with an `:assistant` message containing no `%ToolUse{}` blocks). An
  invalid returned state causes `start_link` to fail with
  `{:error, :invalid_messages}`.

  Return `{:error, reason}` to refuse startup.

  Default: `{:ok, state}` (identity).
  """
  @callback init(state :: State.t()) :: {:ok, State.t()} | {:error, term()}

  @doc """
  Called when the model completes without executable tools.

  Fires after the model responds and there are no tools to execute — either
  the model returned text only, or all tool uses were handled during the
  decision phase. Check `response.stop_reason` for why the model stopped:

    * `:stop` — the model finished naturally
    * `:tool_use` — tool use blocks present but no handlers available
    * `:length` — output was truncated (hit max output tokens)
    * `:refusal` — the model declined due to content or safety policy

  Return `{:stop, state}` to end the turn (listener receives
  `{:agent, pid, :turn, {:stop, response}}`), or `{:continue, content, state}`
  to commit the current segment and append a new user message
  (listener receives `{:agent, pid, :turn, {:continue, response}}`).
  The `content` argument accepts a string or a list of content blocks.

  If a staged prompt exists (from `prompt/3` while running), it overrides this
  callback's decision. See the "Prompt queuing" section in the moduledoc.

  Default: `{:stop, state}`.
  """
  @callback handle_turn(response :: Response.t(), state :: State.t()) ::
              {:stop, State.t()} | {:continue, term(), State.t()}

  @doc """
  Called for each tool use block during the decision phase.

  When the model responds with tool use blocks, this callback is invoked
  sequentially for each one before any tools execute. Return values:

    * `{:execute, state}` — queue the tool for execution
    * `{:reject, reason, state}` — send an error result to the model
    * `{:result, result, state}` — provide a `%ToolResult{}` directly,
      skip execution
    * `{:pause, reason, state}` — pause the agent and send
      `{:agent, pid, :pause, {reason, tool_use}}` to the listener;
      resume later with `resume/2`

  After all decisions are collected, approved tools execute in parallel.
  Rejected and provided results are merged with executed results.

  Default: `{:execute, state}`.
  """
  @callback handle_tool_use(tool_use :: ToolUse.t(), state :: State.t()) ::
              {:execute, State.t()}
              | {:reject, term(), State.t()}
              | {:result, ToolResult.t(), State.t()}
              | {:pause, term(), State.t()}

  @doc """
  Called after each tool executes, before results are sent to the model.

  Invoked sequentially for each result after all approved tools have finished
  executing in parallel. Return `{:ok, result, state}` to pass the result
  through, or modify `result` before returning to alter what the model sees.

  Default: `{:ok, result, state}`.
  """
  @callback handle_tool_result(result :: ToolResult.t(), state :: State.t()) ::
              {:ok, ToolResult.t(), State.t()}

  @doc """
  Called when an LLM request fails entirely.

  This fires when `stream_text` returns `{:error, reason}` — a network
  failure, authentication error, or other request-level problem. This is
  distinct from `handle_turn` with a `:length` or `:refusal` stop reason,
  which means the request succeeded but the model couldn't complete normally.

  Return `{:stop, state}` to surface the error to the listener (the agent
  discards pending messages and goes idle), or `{:retry, state}` to retry
  the same step immediately.

  Default: `{:stop, state}`.
  """
  @callback handle_error(error :: term(), state :: State.t()) ::
              {:stop, State.t()} | {:retry, State.t()}

  @doc """
  Called when the agent process terminates.

  Use for cleaning up resources acquired in `init/1`. Receives the shutdown
  reason and the current state. Standard GenServer termination semantics apply.

  Default: no-op.
  """
  @callback terminate(reason :: term(), state :: State.t()) :: term()

  @genserver_keys [:name, :timeout, :hibernate_after, :spawn_opt, :debug]

  defmacro __using__(_opts) do
    quote do
      @behaviour Omni.Agent

      @impl Omni.Agent
      def init(state), do: {:ok, state}

      @impl Omni.Agent
      def handle_turn(_response, state), do: {:stop, state}

      @impl Omni.Agent
      def handle_tool_use(_tool_use, state), do: {:execute, state}

      @impl Omni.Agent
      def handle_tool_result(result, state), do: {:ok, result, state}

      @impl Omni.Agent
      def handle_error(_error, state), do: {:stop, state}

      @impl Omni.Agent
      def terminate(_reason, _state), do: :ok

      @doc "Starts and links an agent process with this callback module."
      def start_link(opts) do
        Omni.Agent.start_link(__MODULE__, opts)
      end

      defoverridable init: 1,
                     handle_turn: 2,
                     handle_tool_use: 2,
                     handle_tool_result: 2,
                     handle_error: 2,
                     terminate: 2
    end
  end

  @doc """
  Starts and links an agent process without a callback module.

  All default callbacks apply (single turn per prompt, all tools auto-executed,
  errors stop the agent). See "Start options" in the moduledoc for accepted
  keys.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    start_link(nil, opts)
  end

  @doc """
  Starts and links an agent process with the given callback module.

  The module must `use Omni.Agent`. See "Start options" in the moduledoc for
  accepted keys.
  """
  @spec start_link(module() | nil, keyword()) :: GenServer.on_start()
  def start_link(module, opts) do
    {gs_opts, opts} = Keyword.split(opts, @genserver_keys)
    Omni.Agent.Server.start_link({module, opts}, gs_opts)
  end

  @doc """
  Sends a prompt to the agent.

  `content` accepts a string (wrapped in a `Text` block) or a list of content
  blocks (for attachments or `ToolResult` blocks for manual tool execution).
  Options are merged on top of the agent's default `:opts` for this turn only.

  Behaviour depends on agent status:

    * **Idle** — starts a new turn immediately.
    * **Running or paused** — stages the content for the next turn boundary,
      overriding `handle_turn`'s decision. See "Prompt queuing" in the moduledoc.
  """
  @spec prompt(GenServer.server(), term(), keyword()) :: :ok
  def prompt(agent, content, opts \\ []) do
    GenServer.call(agent, {:prompt, content, opts})
  end

  @doc """
  Resumes a paused agent with a tool decision.

  Only valid when the agent is `:paused` (from `handle_tool_use/2` returning
  `{:pause, reason, state}`). The agent continues processing remaining tool
  decisions after resuming.

    * `:execute` — queue the pending tool for execution
    * `{:reject, reason}` — reject with an error result sent to the model
    * `{:result, result}` — provide a `%ToolResult{}` directly

  Returns `{:error, :not_paused}` if the agent is not paused.
  """
  @spec resume(GenServer.server(), :execute | {:reject, term()} | {:result, ToolResult.t()}) ::
          :ok | {:error, :not_paused}
  def resume(agent, decision) do
    GenServer.call(agent, {:resume, decision})
  end

  @doc """
  Cancels the current turn.

  Kills any running tasks, discards pending messages, and emits
  `{:agent, pid, :cancelled, %Response{stop_reason: :cancelled}}`.
  The agent's `state.messages` remains unchanged.

  Returns `{:error, :idle}` if the agent is already idle.
  """
  @spec cancel(GenServer.server()) :: :ok | {:error, :idle}
  def cancel(agent) do
    GenServer.call(agent, :cancel)
  end

  @doc """
  Sets the listener process for agent events.

  Only valid when idle. Returns `{:error, :running}` if the agent is running
  or paused.
  """
  @spec listen(GenServer.server(), pid()) :: :ok | {:error, :running}
  def listen(agent, pid) do
    GenServer.call(agent, {:listen, pid})
  end

  @doc """
  Returns the agent's `%State{}` struct or a single field from it.

  With no key, returns the full `%State{}`. With a key, returns the value of
  that field (or `nil` for unknown keys).

      Agent.get_state(agent)             #=> %State{model: ..., messages: [...], ...}
      Agent.get_state(agent, :status)    #=> :idle
      Agent.get_state(agent, :messages)  #=> [%Message{}, ...]
      Agent.get_state(agent, :private)   #=> %{}
  """
  @spec get_state(GenServer.server()) :: State.t()
  def get_state(agent), do: GenServer.call(agent, :get_state)

  @spec get_state(GenServer.server(), atom()) :: term()
  def get_state(agent, key) when is_atom(key), do: GenServer.call(agent, {:get_state, key})

  @doc """
  Replaces agent configuration fields. Idle only. Atomic.

  Accepts the following keys:

    * `:model` — replace the model. Resolved via `Omni.get_model/2`.
      Fails with `{:error, {:model_not_found, ref}}` if not found
    * `:system` — replace the system prompt
    * `:messages` — replace the committed message history. Must be empty or
      end with an `:assistant` message containing no `%ToolUse{}` blocks;
      otherwise fails with `{:error, :invalid_messages}`
    * `:tools` — replace the tool list
    * `:opts` — replace inference opts

  All values are replaced, not merged. To merge opts, use the function form
  of `set_state/3`.

  `:private` is not settable — callback modules own mutation via
  `%{state | private: ...}`.

  Unrecognized keys return `{:error, {:invalid_key, key}}`.
  Returns `{:error, :running}` if the agent is running or paused.
  """
  @spec set_state(GenServer.server(), keyword()) :: :ok | {:error, :running} | {:error, term()}
  def set_state(agent, opts) when is_list(opts) do
    GenServer.call(agent, {:set_state, opts})
  end

  @doc """
  Replaces or transforms a single configuration field. Idle only.

  When `value_or_fun` is a value, replaces the field directly.
  When `value_or_fun` is a 1-arity function, calls it with the current
  value and uses the return as the new value.

      Agent.set_state(agent, :system, "Be concise.")
      Agent.set_state(agent, :opts, fn opts -> Keyword.merge(opts, temperature: 0.7) end)
      Agent.set_state(agent, :tools, fn tools -> [new_tool | tools] end)

  Settable fields: `:model`, `:system`, `:messages`, `:tools`, `:opts`.
  Returns `{:error, {:invalid_field, field}}` for other fields.
  Returns `{:error, :invalid_messages}` if `:messages` fails the invariant.
  Returns `{:error, :running}` if the agent is running or paused.
  """
  @spec set_state(GenServer.server(), atom(), term() | (term() -> term())) ::
          :ok | {:error, :running} | {:error, term()}
  def set_state(agent, field, value_or_fun) when is_atom(field) do
    GenServer.call(agent, {:set_state, field, value_or_fun})
  end
end
