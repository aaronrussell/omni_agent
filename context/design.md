# Omni Agent Design

**Status:** Implemented
**Last updated:** March 2026

---

## Overview

Omni Agent is a standalone Elixir package that provides a GenServer-based building block for stateful, long-running LLM interactions. It wraps Omni's `stream_text`/`generate_text` pipeline in a supervised process that manages its own conversation context, executes tools, and communicates with callers via process messages.

The core idea: an agent is a process that holds a model, a context (system prompt, messages, tools), and user-defined state. The outside world sends prompts in; the agent works on them (potentially across multiple LLM steps) and sends events back. Users control agent behaviour through a set of lifecycle callbacks.

### What the agent is

- A supervised GenServer process
- Manages its own `%Context{}` (system prompt, messages, tools) and user-defined state
- Communicates asynchronously via process messages
- Behaviour controlled by user-defined callbacks with sensible defaults
- A building block, not a framework -- users compose agents into larger systems

### What the agent is not

- Not a task planner or goal decomposer -- that's application logic
- Not a multi-agent orchestration system -- that sits above the agent
- Not a memory/RAG system -- that's a separate concern
- Not a replacement for `Omni.stream_text`/`Omni.generate_text` -- those remain the stateless API in the `omni` package
- Not a persistence/storage system -- that's an application concern (agent events carry enough context for external persistence)
- Not a session manager -- the agent owns the **turn**, the application owns the **session** (navigation, branching, persistence, cumulative usage)

---

## Relationship to Omni

Omni Agent depends on the `omni` package and builds on top of its stateless API. Omni provides:

- **`Omni.Loop`** -- handles tool auto-execution and structured output validation within a single `stream_text` / `generate_text` call. Stateless, lazy stream pipeline.
- **`Omni.stream_text/3` / `Omni.generate_text/3`** -- stateless functions. Caller provides context, gets a response, manages conversation history externally.

Omni Agent adds:

- **State management** -- the agent holds a `%Context{}` so the caller doesn't have to thread messages through.
- **Its own loop** -- after each LLM step completes, the agent decides whether to continue (re-prompt) or stop, based on user-defined callbacks.
- **Lifecycle hooks** -- callbacks for intercepting tool execution, handling errors, and controlling continuation.

The agent does **not** use `Omni.Loop` for tool execution. It calls `stream_text` with `max_steps: 1`, so Loop handles single-step streaming, event parsing, and structured output validation but never enters its tool execution loop. The agent manages tool execution itself via lifecycle callbacks (`handle_tool_use`, `handle_tool_result`), enabling per-tool approval gates and pause/resume that Loop's stateless design cannot support.

```
┌─────────────────────────────────────────────────┐
│  Omni.Agent (GenServer)          [omni_agent]   │
│  - Manages context and state                    │
│  - Decides continue/stop between steps           │
│  - Lifecycle callbacks                          │
│  - Tool execution with per-tool interception    │
│                                                 │
│  Uses stream_text(max_steps: 1) per step:        │
│  ┌───────────────────────────────────────────┐  │
│  │  Single LLM request via Omni.Loop [omni]  │  │
│  │  - Streaming event pipeline               │  │
│  │  - Structured output validation           │  │
│  │  - No tool looping (max_steps: 1)         │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### Dependency surface

Omni Agent imports the following from `omni`:

- `Omni.stream_text/3` — the sole integration point for LLM requests (called in `Step`)
- `Omni.{Context, Message, Model, Response, Tool, Usage}` — data structs
- `Omni.Content.{Text, Thinking, ToolResult, ToolUse}` — content blocks
- `Omni.Tool.Runner` — parallel tool execution (called in `Executor`)

The dependency is strictly one-directional. Core Omni has zero knowledge of Omni Agent.

---

## Agent definition

### Starting an agent

`Omni.Agent` is the GenServer module. It accepts an optional callback module for custom behaviour:

```elixir
# No custom module -- default callbacks (no continuation, no interception)
{:ok, agent} = Omni.Agent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a helper."
)

# Custom module -- Omni.Agent dispatches to MyAgent's callbacks
{:ok, agent} = Omni.Agent.start_link(MyAgent,
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a research assistant.",
  tools: [SearchTool.new(), FetchTool.new()]
)
```

`Omni.Agent.start_link/1` (opts only) and `Omni.Agent.start_link/2` (module + opts).

### Custom agent modules

`use Omni.Agent` generates a `start_link/1` that delegates to `Omni.Agent.start_link/2` with the module baked in:

```elixir
defmodule MyAgent do
  use Omni.Agent

  def handle_turn(%{stop_reason: :length}, state) do
    {:continue, "Continue where you left off.", state}
  end
  def handle_turn(_response, state), do: {:stop, state}
end

{:ok, agent} = MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a research assistant."
)
```

For reusable defaults, override `start_link` -- standard GenServer pattern:

```elixir
defmodule MyAgent do
  use Omni.Agent

  def start_link(opts \\ []) do
    defaults = [
      model: {:anthropic, "claude-sonnet-4-20250514"},
      system: "You are a research assistant.",
      tools: [SearchTool.new(), FetchTool.new()]
    ]
    super(Keyword.merge(defaults, opts))
  end

  # callbacks...
end

MyAgent.start_link()                              # uses defaults
MyAgent.start_link(model: {:openai, "gpt-4o"})   # overrides model
```

All configuration flows through `start_link` opts. No config in the `use` macro -- the module provides behaviour (callbacks), `start_link` provides configuration (data). This avoids merge ambiguity and handles dynamic values naturally.

### GenServer options

Known GenServer keys (`:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`, `:debug`) are extracted from the flat opts and passed to `GenServer.start_link/3`. No nested `:server` key:

```elixir
MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  name: {:via, Registry, {MyRegistry, :agent_1}}
)
```

### Agent opts (passed through to stream_text)

LLM request options (`:temperature`, `:max_tokens`, etc.) are passed under the `:opts` key to keep them separate from agent-level configuration:

```elixir
MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-20250514"},
  system: "You are a helper.",
  tool_timeout: 10_000,
  opts: [temperature: 0.7, max_tokens: 4096]
)
```

`:tool_timeout` sets the maximum time (in milliseconds) for each individual tool execution. Defaults to `5_000` (5 seconds). When a tool exceeds this timeout, its Tool Task is killed and an error `ToolResult` is sent to the model. Applied uniformly to all tools — no per-tool configuration.

---

## Agent state

Agent state is split into two structs: a public `%Omni.Agent.State{}` passed to all callbacks, and an internal `%Omni.Agent.Server{}` struct that wraps it alongside GenServer machinery. Callback implementors only see the public struct.

### Public state (`Omni.Agent.State`)

The public state is a 7-field struct. User-defined state is split into `meta` (user metadata) and `private` (runtime, not persisted).

```elixir
defmodule Omni.Agent.State do
  defstruct [
    :model,                           # %Model{} — the agent's model
    :opts,                            # keyword — agent-level default inference opts
    context: %Context{},              # %Context{} — system prompt, messages, tools
    meta: %{},                        # user metadata (title, tags, custom domain data)
    private: %{},                     # runtime state (PIDs, refs — not persisted)
    status: :idle,                    # :idle | :running | :paused
    step: 0                           # current step counter within the active turn
  ]
end
```

The fields have two logical tiers:

- **Configuration** — `model`, `context`, and `opts` are set at `start_link` and changeable via `set_state/2,3` (idle only). `context` holds the system prompt, committed messages, and tools. `opts` holds agent-level inference defaults (`:temperature`, `:max_tokens`, `:max_steps`, etc.).
- **Session state** — `meta`, `private`, `status`, and `step` change during operation. `meta` is user metadata. `private` is runtime state. `step` resets per turn.

All callbacks receive this public `%State{}` struct. Users can read any field and primarily read/write `meta` and `private`. The framework manages the other fields.

Note: `context.messages` only reflects **committed** messages from completed turns. Messages accumulated during the current in-progress turn are held internally as `pending_messages` and are not visible in callbacks.

### Internal server state (`Omni.Agent.Server`)

The server struct wraps the public state and adds all internal machinery. It is never passed to callbacks.

```elixir
defstruct [
  # Public state (passed to callbacks)
  :state,                             # %State{} — the public struct

  # Configuration (set at init, stable across turns)
  :module,                            # module() | nil — callback module
  :listener,                          # pid | nil — event recipient
  :tool_timeout,                      # timeout — per-agent tool execution timeout

  # Turn lifecycle (reset per turn)
  pending_messages: [],               # messages accumulated during the current turn
  pending_usage: %Usage{},            # accumulated usage for current turn
  prompt_opts: [],                    # per-turn merged opts
  next_prompt: nil,                   # staged prompt (steering)
  last_response: nil,                 # most recent Response from a step

  # Process tracking
  step_task: nil,                     # {pid, ref} | nil — current step process
  executor_task: nil,                 # {pid, ref} | nil — current executor process

  # Tool decision phase (set when decisions begin, cleared by reset_turn)
  tool_map: nil,                      # name → Tool lookup
  approved_uses: [],                  # already-approved tool uses (reversed)
  remaining_uses: [],                 # tool uses not yet presented to handle_tool_use
  rejected_results: [],               # stashed rejected tool results
  provided_results: [],               # stashed results from {:result, ...} returns
  paused_use: nil,                    # the tool_use awaiting a human decision
  paused_reason: nil                  # the reason from {:pause, reason, state}
]
```

During a turn, messages accumulate in `pending_messages`. LLM requests see `context.messages ++ pending_messages`. On turn completion (`:done`), pending messages are committed to `context.messages`. On cancel or error, pending messages are discarded — the context stays clean.

`pending_usage` accumulates usage across steps within a turn and is included in the `:done` response. The agent does not track cumulative session usage — that's an application concern.

### What the state does NOT store

- **Cumulative usage** — the application tracks this across turns from `:done` events.
- **Responses** — the listener receives `%Response{}` via `:continue` and `:done` events. If the listener wants to collect responses, it does so in its own process state.
- **Raw request/response pairs** — the `:raw` option can be passed per-prompt via `prompt/3` opts and flows through to `stream_text`. Each `%Response{}` delivered via events carries its own `raw` field.
- **Conversation history structure** — the application manages its own session structure (trees, flat logs, database) and feeds messages to the agent via `set_state`.

### max_steps lives in opts

`max_steps` is stored in `opts` (the agent-level default) and can be overridden per-prompt via `prompt/3` opts. The per-prompt override is ephemeral — it only applies to that turn. Next turn, the agent falls back to the default in `opts`. This is handled via keyword merge into `prompt_opts` at the start of each turn.

---

## Public API

The agent communicates with callers via process messages. This is the natural Elixir pattern for long-lived processes and works well with GenServers, LiveViews, and Phoenix Channels.

### Full API surface

```elixir
# Lifecycle
Omni.Agent.start_link(opts)                        # no custom module
Omni.Agent.start_link(module, opts)                # with callback module

# Interaction
Agent.prompt(agent, content, opts \\ [])           # send prompt / steer
Agent.resume(agent, decision)                      # resume from tool approval pause
Agent.cancel(agent)                                # abort and discard pending

# State management (idle only)
Agent.set_state(agent, opts)                       # → :ok | {:error, ...}
Agent.set_state(agent, field, value_or_fun)        # → :ok | {:error, ...}

# Listener
Agent.listen(agent, pid)                           # → :ok | {:error, :running}

# Inspection
Agent.get_state(agent)                             # → %State{}
Agent.get_state(agent, :model)                     # → %Model{}
Agent.get_state(agent, :status)                    # → :idle | :running | :paused
```

### prompt/2,3

```elixir
# Simple text prompt
:ok = Agent.prompt(agent, "Do some research on Elixir web frameworks")

# With attachments (content blocks)
:ok = Agent.prompt(agent, [
  Text.new("What's in this image?"),
  Attachment.new(source: {:base64, data}, media_type: "image/png")
])

# With per-prompt option overrides
:ok = Agent.prompt(agent, "Do some research",
  max_steps: 50,
  temperature: 0.7,
  max_tokens: 100
)

# Steering -- prompt while running or paused stages for next handle_turn
:ok = Agent.prompt(agent, "Focus on X instead")
```

`prompt/2,3` is a `GenServer.call`. The `content` argument accepts a string (wrapped in a `Text` block) or a list of content blocks (for attachments). The agent constructs the user `Message` internally. Options: `:max_steps` overrides the agent's step limit for this turn only (see "Turns and steps"). Everything else is passed through to `stream_text` as per-prompt inference overrides.

If no listener has been set (via `Agent.listen/2`), the first `prompt/3` call automatically sets the caller as the listener. See "Listener" section below.

Behaviour depends on agent status:

- **Idle**: starts working immediately. Events arrive as process messages to the listener.
- **Running or Paused**: the prompt is staged as a pending prompt. At the next `handle_turn` callback, the pending prompt overrides `handle_turn`'s decision (see "Prompt queuing"). Calling `prompt/3` again replaces the staged prompt — last-one-wins. The caller is assumed to be the same entity updating its intent.

### resume/2

```elixir
Agent.resume(agent, :execute)              # execute the paused tool
Agent.resume(agent, {:reject, reason})     # reject with reason
Agent.resume(agent, {:result, result})     # supply a result directly (skip execution)
```

Only valid when the agent is `:paused` (from `handle_tool_use` returning `{:pause, reason, state}`). Returns `{:error, :not_paused}` otherwise. See "Pause and resume" section below.

### cancel/1

```elixir
Agent.cancel(agent)
```

Aborts the current operation. Kills any running Step/Executor/Tool Tasks, discards `pending_messages` and `pending_usage`, and emits `{:agent, pid, :cancelled, %Response{stop_reason: :cancelled}}`. The agent's `context.messages` remains unchanged.

Works when `:running` or `:paused`. Returns `{:error, :idle}` if already idle.

### set_state/2

```elixir
Agent.set_state(agent, context: %Context{system: "Be concise.", tools: [...]})
Agent.set_state(agent, opts: [temperature: 0.7])
```

Replaces agent configuration fields. Accepts: `:model`, `:context`, `:opts`, `:meta`. All values are replaced, not merged. Atomic — if model resolution fails, no changes are applied. Idle only.

### set_state/3

```elixir
Agent.set_state(agent, :context, fn ctx -> %{ctx | system: "Be concise."} end)
Agent.set_state(agent, :opts, fn opts -> Keyword.merge(opts, temperature: 0.7) end)
Agent.set_state(agent, :meta, fn meta -> Map.put(meta, :title, "Research") end)
```

Replaces or transforms a single field. When the third argument is a 1-arity function, it receives the current value and returns the new value. When it's a plain value, it replaces directly. Same settable fields as `set_state/2`. Idle only.

### Listener

The listener is the process that receives `{:agent, pid, type, data}` events. Managed separately from prompting:

```elixir
# Explicit — set before or after first prompt (idle only)
Agent.listen(agent, self())

# Implicit — first prompt/3 caller becomes listener if none set
:ok = Agent.prompt(agent, "hello")   # caller is now the listener
```

The listener starts as `nil` after `start_link`. The first `prompt/3` call sets the caller as the listener if none has been explicitly set. After that, the listener persists across turns until explicitly changed via `listen/2`.

`listen/2` returns `:ok` when idle, `{:error, :running}` otherwise — same idle-only constraint as `set_state/2,3`. This avoids mid-turn listener changes and the ambiguity of who receives in-flight events.

### Inference opts merge order

Per-prompt inference options (passed through `prompt/3`) merge on top of agent-level defaults (set in `start_link` under `:opts`). Agent defaults ← per-prompt opts. The merged options are passed to `stream_text` for each step.

### Event format

All events from the agent follow the format `{:agent, agent_pid, event_type, event_data}`:

```elixir
# SR pass-through events (streaming content from each step)
{:agent, pid, :text_start, %{index: 0}}
{:agent, pid, :text_delta, %{index: 0, delta: "Hello"}}
{:agent, pid, :text_end, %{index: 0, content: %Text{}}}
{:agent, pid, :thinking_start, %{index: 0}}
{:agent, pid, :thinking_delta, %{index: 0, delta: "..."}}
{:agent, pid, :thinking_end, %{index: 0, content: %Thinking{}}}
{:agent, pid, :tool_use_start, %{index: 1, id: "call_1", name: "search"}}
{:agent, pid, :tool_use_delta, %{index: 1, delta: "{\"q\":"}}
{:agent, pid, :tool_use_end, %{index: 1, content: %ToolUse{}}}

# Agent-level events
{:agent, pid, :tool_result, %ToolResult{}}    # after tool execution
{:agent, pid, :continue, %Response{}}         # continuation point, agent continuing
{:agent, pid, :done, %Response{}}             # turn complete
{:agent, pid, :pause, {reason, %ToolUse{}}}   # waiting for tool approval
{:agent, pid, :cancelled, %Response{}}        # cancel was invoked, pending discarded
{:agent, pid, :retry, reason}                # non-terminal error, agent retrying step
{:agent, pid, :error, reason}                # terminal error, agent goes idle
```

**SR pass-through events** are forwarded from the Step Task as the LLM streams its response.

**Agent-level events** are emitted by the GenServer itself. `:done`, `:continue`, and `:cancelled` carry a `%Response{}` with `messages` — all messages accumulated during the turn. `:done` messages are committed to `context.messages`; `:cancelled` messages are discarded. `:error` carries the bare error reason term — the agent discards pending state and goes to `:idle`. `:retry` is emitted when `handle_error` returns `{:retry, state}` — it carries the error reason and signals that a new step will follow. `:tool_result` carries `%ToolResult{}`, `:pause` carries `{reason, %ToolUse{}}`.

**Continuation points:** `:continue` fires at each continuation point (where `handle_turn` returned `{:continue, ...}`). `:done` fires when the turn ends. A simple chatbot (single step, no continuation) never sees `:continue`, only `:done`.

```
# Simple chatbot (single step, no tools)
text_delta, text_delta, ..., done

# Single turn with tools (multiple steps)
text_delta, tool_use_start, ..., tool_use_end, tool_result,
text_delta, ..., done

# Autonomous agent (3 continuations)
text_delta, ..., tool_use_end, tool_result, text_delta, ..., continue,
text_delta, ..., continue,
text_delta, ..., done
```

### Usage patterns

In a receive loop (scripts, IEx):

```elixir
:ok = Agent.prompt(agent, "Do the thing")

receive do
  {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
  {:agent, ^agent, :pause, {_reason, tool_use}} ->
    Agent.resume(agent, :execute)
  {:agent, ^agent, :done, response} -> handle_result(response)
end
```

In a LiveView:

```elixir
def handle_event("submit", %{"prompt" => text}, socket) do
  :ok = Agent.prompt(socket.assigns.agent, text)
  {:noreply, socket}
end

def handle_info({:agent, _pid, :text_delta, %{delta: text}}, socket) do
  {:noreply, stream_insert(socket, :messages, %{type: :text, text: text})}
end

def handle_info({:agent, _pid, :continue, _response}, socket) do
  {:noreply, assign(socket, :status, "Agent continuing...")}
end

def handle_info({:agent, _pid, :done, response}, socket) do
  {:noreply, assign(socket, status: "Complete", response: response)}
end

def handle_info({:agent, _pid, :cancelled, _}, socket) do
  {:noreply, assign(socket, :status, "Cancelled")}
end
```

---

## Process architecture

The agent GenServer never blocks on IO. All blocking work (LLM requests, tool execution) is delegated to spawned Tasks. This keeps the GenServer responsive for cancel, state inspection, and resume calls at all times.

### Three Task layers

- **Step Task** -- one per LLM request (step). Calls `Omni.stream_text` with `max_steps: 1`, enumerates the `StreamingResponse`, and forwards events to the GenServer via a tagged ref. The Task owns the HTTP connection via `Req.request(into: :self)` -- Finch messages go to the Task's mailbox, not the GenServer's.

- **Executor Task** -- one per tool execution batch. Calls `Omni.Tool.Runner.run/3` in a linked Task, collects results, and sends all results back to the GenServer.

- **Tool Tasks** -- one per tool. Spawned by `Tool.Runner`. Calls `Tool.execute/2` for a single tool. Short-lived.

### Fault tolerance

All tasks are linked to the GenServer but designed never to crash — task bodies are wrapped in try/rescue and always send a result message. The GenServer traps exits as defense-in-depth. No `Task.Supervisor` needed.

**Step process** — wraps its body in try/rescue. On success, sends `{ref, {:complete, response}}`. On exception, sends `{ref, {:error, reason}}`. The GenServer routes errors to `handle_error` as normal.

**Executor Task** — uses `Task.yield_many/2` instead of `Task.await_many/2` to collect tool results. This handles per-tool timeouts and crashes gracefully without raising.

**Tool Tasks** — `Tool.execute/2` already has its own rescue block, so Tool Tasks virtually never crash. The `yield_many` handling above is defense-in-depth.

### Tool use decision flow

When the model produces tool use blocks, the GenServer processes them in two phases:

1. **Decision phase** (synchronous, in GenServer): iterate tool uses, invoke `handle_tool_use` for each. Collect decisions. Rejected tools get error `ToolResult`s immediately without execution. Tools with `{:result, result, state}` get their result recorded without execution. When `{:pause, reason, state}` is returned, the decision loop is interrupted — the agent saves its position and waits for `Agent.resume/2`.

2. **Execution phase** (async, in executor Task): approved tools execute in parallel via `Tool.Runner.run/3`. Results sent back to GenServer. GenServer merges with rejected and pre-supplied results, then invokes `handle_tool_result` for each.

---

## Lifecycle callbacks

All callbacks are optional with `defoverridable` defaults. Users implement only the callbacks they need.

### init/1

Called once when the agent starts. Receives the full opts passed to `start_link`. Returns `{:ok, private}` or `{:error, reason}`.

Default: `{:ok, %{}}` (empty private).

### handle_tool_use/2

Called before a tool is executed, during the decision phase. Called sequentially for each tool use — all decisions are collected before any tool executes.

Returns: `{:execute, state}`, `{:result, result, state}`, `{:reject, reason, state}`, or `{:pause, reason, state}`.

Default: `{:execute, state}` (execute all tools).

### handle_tool_result/2

Called after a tool executes, during the result phase. Called sequentially for each result after all approved tools have executed in parallel.

Returns: `{:ok, result, state}` (can modify result before sending to model).

Default: `{:ok, result, state}` (pass through).

### handle_turn/2

Called when the model responds without executable tool uses, or when tool uses have been handled and the model responds to the results, or when approved tools have no handlers (stop_reason: `:tool_use`).

The stop reason is available as `response.stop_reason` (`:stop`, `:tool_use`, `:length`, `:refusal`).

Returns: `{:stop, state}` (end turn, emit `:done`) or `{:continue, prompt, state}` (append user message, continue).

Default: `{:stop, state}` (always stop).

If a pending prompt exists (from `prompt/3` while running), it overrides `handle_turn`'s return value. See "Prompt queuing" section.

### handle_error/2

Called when the LLM request fails entirely -- `Omni.stream_text` returned `{:error, reason}`.

Returns: `{:stop, state}` (discard pending messages, go to `:idle`, emit `:error` event) or `{:retry, state}` (retry the same step immediately).

Default: `{:stop, state}`.

Note: HTTP-level retries (429, 529, etc.) should be handled by Req middleware before reaching the agent. `handle_error` is for errors that survive the middleware layer.

### terminate/2

Called when the agent process is shutting down. Use for cleaning up resources acquired in `init/1`.

Default: no-op.

---

## Autonomous agents and the completion signal

The difference between a chatbot (single step, no continuation) and an autonomous agent (works until done) is entirely in the callbacks. The framework doesn't distinguish between these modes.

### The completion tool pattern

An autonomous agent uses a tool with a trivial handler as its completion signal:

```elixir
task_complete = Omni.tool(
  name: "task_complete",
  description: "Call when the task is fully complete.",
  input_schema: Omni.Schema.object(
    %{result: Omni.Schema.string(description: "Summary of what was accomplished")},
    required: [:result]
  ),
  handler: fn _input -> "OK" end
)
```

When the model calls `task_complete`, the tool executes like any other tool (flowing through `handle_tool_use` and `handle_tool_result`). The model then responds to the tool result, and `handle_turn` fires with `stop_reason: :stop`. The agent stops at `handle_turn` after the tool executes and the model responds.

### Turns and steps

The agent's loop has two conceptual levels:

- **Turn** -- the top-level cycle, starting with `prompt/3` and ending with `:done`. A turn may contain multiple steps. When `handle_turn` returns `{:continue, ...}`, the agent continues within the same turn.
- **Step** -- a single LLM request-response cycle. If the model responds with tool use blocks, the agent handles them and makes a new request with the tool results. `handle_turn` fires when a step completes without tool uses.

### max_steps

A single `max_steps` option (default `:infinity`) caps the total number of LLM requests across the entire turn. The step counter resets when a new turn begins.

When hit: `handle_turn` still fires, but if it returns `{:continue, ...}`, the agent overrides the decision and stops. The listener receives `{:done, response}` as normal.

---

## Pause and resume

Pause exists for exactly one purpose: **tool use approval**. Only `handle_tool_use` can return `{:pause, reason, state}`. No other callback pauses.

When `handle_tool_use` returns `{:pause, reason, state}`:

- The agent's status becomes `:paused`
- The agent sends `{:agent, pid, :pause, {reason, tool_use}}` to the listener
- The agent waits for `Agent.resume/2`
- `prompt/3` stages the content as a pending prompt (same as when running)

On `:execute`, the GenServer approves the tool and continues collecting decisions for remaining tools. On `{:reject, reason}`, the tool gets an error `ToolResult` and the GenServer continues with the next tool. On `{:result, result}`, the result is recorded directly and the GenServer continues without executing the tool.

---

## Prompt queuing (steering)

When the agent is running, the caller can steer it by sending a new prompt:

```elixir
:ok = Agent.prompt(agent, "Stop what you're doing, focus on X instead")
```

The prompt is **staged**. At the next `handle_turn` callback:

- `handle_turn` fires as normal (for bookkeeping, state updates)
- The staged prompt overrides `handle_turn`'s decision
- Calling `prompt/3` again replaces the staged prompt — last-one-wins

---

## Context management

### Pending messages model

Messages accumulate in `pending_messages` during a turn, not directly in the context. Each operation appends:

- `prompt/3` → append user message to `pending_messages`
- Step completes → append assistant message to `pending_messages`
- Tools executed → append tool result user message to `pending_messages`
- `{:continue, prompt}` → append continuation user message to `pending_messages`

`build_context/1` creates the LLM request context as `context.messages ++ pending_messages`.

On `:done`, pending messages are committed: `context.messages = context.messages ++ pending_messages`. On cancel or error, they're discarded — `context.messages` stays unchanged.

### evaluate_head state machine

A single `evaluate_head/1` function examines the last pending message and decides the next action:

| Last pending message | Action |
|---|---|
| User message | Spawn step (generate next response) |
| Assistant message with tool uses | Enter tool decision phase |
| Assistant message without tool uses | Call `handle_turn` callback |

All operations funnel through `evaluate_head`: prompt appends a user message then calls it, step completion appends an assistant message then calls it, tool execution appends results then calls it.

### Cancel semantics

`Agent.cancel/1` aborts the current operation:

1. Kills any running Step/Executor/Tool Tasks
2. Builds an incomplete `%Response{stop_reason: :cancelled}` with pending messages
3. Discards `pending_messages` and `pending_usage` via `reset_turn`
4. Agent returns to `:idle`
5. Listener receives `{:agent, pid, :cancelled, %Response{}}`

The context remains unchanged — only committed messages survive.

### Error recovery

When a step fails and `handle_error/2` returns `{:stop, state}`:

- Pending messages and usage are discarded via `reset_turn`
- The agent goes to `:idle` (not a separate error status)
- Listener receives `{:agent, pid, :error, reason}` with the bare error term
- The app can immediately `prompt/3` again or `set_state` to adjust context

When `handle_error/2` returns `{:retry, state}`, the agent stays `:running` and retries the same step immediately. Pending messages are preserved.

---

## What users build on top

The agent provides mechanism; users provide policy:

| Omni Agent provides | Users build on top |
|---|---|
| Stateful conversation process | Domain-specific system prompts |
| Dynamic tool management | Which tools to give the agent when |
| Outer loop with continuation callbacks | Goal evaluation logic |
| Pause/resume mechanism | Approval UIs, human-in-the-loop flows |
| Process lifecycle (supervised, named) | Multi-agent orchestration |
| Streaming events to caller | UI layer, logging, metrics |
| Error handling callbacks | Retry strategies, fallback logic |
| | Session management (persistence, branching) |
| | Task decomposition / planning |
| | Memory / RAG integration |
| | Agent-to-agent communication |

---

## Module layout

```
lib/omni/
├── agent.ex                    # Public module: behaviour, use macro, callback defaults, API
├── agent/
│   ├── state.ex                # %Omni.Agent.State{} — public state passed to callbacks
│   ├── server.ex               # Internal GenServer: handle_call, handle_info, state machine,
│   │                            # step spawning, tool decision/execution, event forwarding (@moduledoc false)
│   ├── step.ex                 # Step process: streams LLM request, forwards events via
│   │                            # tagged ref (@moduledoc false)
│   └── executor.ex             # Executor process: calls Tool.Runner.run in a linked Task,
│                                # sends results back via tagged ref (@moduledoc false)
```

`agent.ex` is what users interact with — `use Omni.Agent`, callback definitions, and public API functions (thin `GenServer.call` wrappers). `agent/server.ex` is the internal GenServer — state transitions, task management, pending messages, tool decision/execution phases, event routing. `agent/step.ex` encapsulates the streaming execution logic. `agent/executor.ex` is a thin Task wrapper that calls `Tool.Runner.run/3`. The server, step, and executor modules are not part of the public API.
