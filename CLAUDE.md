# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni Agent is an Elixir package that provides a GenServer-based building block for stateful, long-running LLM interactions. It builds on top of the [`omni`](https://github.com/aaronrussell/omni) package, wrapping its stateless `stream_text`/`generate_text` API in a supervised process that manages conversation context, executes tools, and communicates with callers via process messages.

The package is separated from `omni` because the stateless LLM API layer (omni) is stable, while the agent layer is under active experimentation and rapid iteration.

### Core idea

An agent is a process that holds a model, a context (system prompt, messages, tools), and user-defined state. The outside world sends prompts in; the agent works on them (potentially across multiple LLM steps) and sends events back. Users control behaviour through lifecycle callbacks.

The agent owns the **turn** (a complete prompt-to-stop cycle), while the **application** owns the session (persistence, branching, navigation, cumulative usage tracking). During a turn, messages accumulate internally as `pending_messages`. On success (`{:stop, response}`), they're committed to `context.messages`. On cancel or error, they're discarded — the context always stays in a valid state.

### What lives here vs in `omni`

| This package (`omni_agent`) | Parent package (`omni`) |
|---|---|
| `Omni.Agent` — behaviour, `use` macro, public API | `Omni.stream_text/3`, `Omni.generate_text/3` |
| `Omni.Agent.Server` — GenServer internals | `Omni.Context`, `Omni.Message`, `Omni.Response` |
| `Omni.Agent.State` — public state struct | `Omni.Tool`, `Omni.Tool.Runner` |
| `Omni.Agent.Step` — LLM request task | `Omni.Model`, `Omni.Usage` |
| `Omni.Agent.Executor` — tool execution task | `Omni.Content.*` content blocks |
| | Providers, dialects, streaming pipeline |

The dependency is strictly one-directional — `omni_agent` depends on `omni`, never the reverse. The sole integration point for LLM requests is `Omni.stream_text/3` (called in `Step`). Tool execution uses `Omni.Tool.Runner.run/3` (called in `Executor`).

See the [Context Document](#context-document) for the full design reference.

## Build & Development Commands

```bash
mix compile                   # Compile the project
mix test                      # Run all tests
mix test path/to/test.exs     # Run a single test file
mix test path/to/test.exs:42  # Run a specific test (line number)
mix format                    # Format all code
mix format --check-formatted  # Check formatting without changing files
```

## Dependencies

- **Omni** — the parent LLM API package (local path dep during development, hex dep for release)
- **Plug** (test only) — required for `Req.Test` plug-based mocking

All other transitive dependencies (Req, Peri, etc.) come through `omni`.

## Architecture

### Process model

The agent GenServer never blocks on IO. All blocking work is delegated to spawned Tasks:

- **Step Task** (`Omni.Agent.Step`) — one per LLM request. Calls `Omni.stream_text` with `max_steps: 1`, enumerates the `StreamingResponse`, and forwards events to the GenServer via a tagged ref. The GenServer remains responsive for cancel/resume/inspect at all times.
- **Executor Task** (`Omni.Agent.Executor`) — one per tool execution batch. Calls `Omni.Tool.Runner.run/3` in a linked Task and sends results back.
- **Tool Tasks** — spawned by `Tool.Runner` internally, one per tool, executed in parallel.

### State split

Agent state is split into two structs:

- **`Omni.Agent.State`** — the public struct passed to all callbacks. Contains `model`, `system`, `messages`, `tools`, `opts`, `private`, `status`, `step`.
- **`Omni.Agent.Server`** (internal) — wraps `State` and adds GenServer machinery: task refs, pending messages/usage, tool decision state, staged prompts. Never exposed to callbacks.

### State and pending messages

Messages live directly on `state.messages`. The agent rebuilds a `%Context{system, messages, tools}` on each call to `Omni.stream_text/3` internally. During a turn, new messages (user prompt, assistant responses, tool results) accumulate in `pending_messages` (internal server state). LLM requests see `state.messages ++ pending_messages`. On `{:stop, ...}`, pending messages are committed to `state.messages`. On cancel or error, they're discarded.

This design means `state.messages` is always in a valid state — no trailing user messages after cancel/error. The application can use `set_state/2,3` to update fields (swap messages for navigation, hydrate a session, etc.) when the agent is idle. `set_state(:messages, ...)` validates the list ends with an `:assistant` message containing no `ToolUse` blocks (or is empty).

### Agent loop

The agent loop operates at two levels:

- **Step** — a single LLM request-response. If the model calls tools, the agent handles them and makes another request.
- **Turn** — starts with `prompt/3`, ends with `{:stop, response}`. `handle_turn` fires when the model responds without executable tools. If it returns `{:continue, ...}`, the agent keeps working within the same turn.

A single `evaluate_head/1` function drives the state machine: last pending message is a user message → spawn step, assistant with tool uses → tool decision phase, assistant without → `handle_turn`.

The agent does **not** use `Omni.Loop` for tool execution — it calls `stream_text` with `max_steps: 1` so Loop never enters its tool loop. The agent manages tools itself via `handle_tool_use`/`handle_tool_result` callbacks, enabling per-tool approval gates and pause/resume.

### Tool decision flow

When the model produces tool use blocks, all tool uses flow through `handle_tool_use/2`:

1. **Decision phase**: `handle_tool_use` called sequentially for each tool use — returns `{:execute, state}`, `{:reject, reason, state}`, `{:result, result, state}`, or `{:pause, reason, state}`
2. **Execution check**: if any approved tool lacks a handler → `handle_turn` with `stop_reason: :tool_use`
3. **Execution phase**: approved tools run in parallel via `Tool.Runner.run/3`, results (executed + rejected + provided) passed to `handle_tool_result`

## Module Layout

```
lib/omni/
├── agent.ex                    # Public module: behaviour, use macro, callback defaults, API
├── agent/
│   ├── state.ex                # Public state struct passed to callbacks
│   ├── server.ex               # Internal GenServer (@moduledoc false)
│   ├── step.ex                 # Step process: streams LLM request (@moduledoc false)
│   └── executor.ex             # Executor process: parallel tool execution (@moduledoc false)
```

## Conventions

- The term is "tool use", not "tool call" (aligns with Anthropic's API, consistent with `omni`).
- Agent statuses: `:idle`, `:running`, `:paused`. Status determines which API calls are valid.
- All callbacks are optional with `defoverridable` defaults. Users implement only what they need.
- `set_state/2` (keyword list, replaces by key, atomic) and `set_state/3` (single field + value or function). Settable fields: `:model`, `:system`, `:messages`, `:tools`, `:opts`. `:private` is not settable — callback modules own mutation.
- `:step` events carry the per-step `%Response{}` from each LLM request. `:stop`, `:continue`, and `:cancelled` events carry a `%Response{}` with `messages` — all messages from the turn. `:error` carries the bare error reason term.
- The agent has no `session_id` or built-in persistence — session identity and storage are application concerns. The `{:stop, response}` event carries enough context (`messages`, `usage`) for external listeners to persist.
- `prompt/3` behaviour depends on status: idle → start turn, running/paused → stage for next turn boundary (steering).
- On error (after `handle_error/2` returns `{:stop, state}`), pending messages are discarded and the agent goes to `:idle`. The app can prompt again immediately.

## Testing

Tests live in `test/omni/agent/` and use `Req.Test.stub/2` with a plug to simulate HTTP responses. Tests exercise the full agent lifecycle through the public `Omni.Agent` API: prompt/response, tool execution, pause/resume, cancel, error handling, continuation, steering, set_state, and more. A shared `Omni.Agent.AgentCase` (`test/support/agent_case.ex`) provides helpers for stubbing fixtures, starting agents, and collecting events.

**Fixtures:** SSE fixtures in `test/support/fixtures/sse/` are real Anthropic API recordings copied from the `omni` package. Three fixtures: `anthropic_text.sse` (text response), `anthropic_tool_use.sse` (tool use response), and `anthropic_thinking.sse` (thinking response). Tests compose these via `stub_fixture` (single response) and `stub_sequence` (ordered responses for multi-step scenarios).

No tests require API keys. `test/support/` is compiled in the test environment via `elixirc_paths`.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless the type is complex enough to warrant further explanation.
- All public functions must have a `@doc`. One sentence is fine if the function is self-explanatory; add more detail for complex behaviour. Rely on `@spec` for types — don't repeat type info in prose.
- Private functions (`defp`) do not need `@doc` annotations.
- Tone: practical over theoretical, concise, example-driven for key APIs. Lead with what you do, not what things are.

## Context Document

The `context/` directory contains detailed design and planning documents. This CLAUDE.md provides sufficient context for most tasks — consult the design doc when working in depth on the agent internals.

- **`context/design.md`** — Full architecture reference covering: relationship to `omni`, public API (`prompt`, `set_state`), lifecycle callbacks (`init`, `handle_tool_use`, `handle_tool_result`, `handle_turn`, `handle_error`, `terminate`), process model (Step/Executor/Tool Tasks), pause/resume, prompt queuing/steering, context and pending messages model, the completion tool pattern, and the evaluate_head state machine.
