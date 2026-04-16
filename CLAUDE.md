# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Omni Agent is an Elixir package that provides a GenServer-based building block for stateful, long-running LLM interactions. It builds on top of the [`omni`](https://github.com/aaronrussell/omni) package, wrapping its stateless `stream_text`/`generate_text` API in a supervised process that manages conversation context, executes tools, and communicates with callers via process messages.

The package is separated from `omni` because the stateless LLM API layer (omni) is stable, while the agent layer is under active experimentation and rapid iteration.

### Core idea

An agent is a process that holds a model, a system prompt, a list of tools, a branching `%Omni.Agent.Tree{}` of messages, and user-defined state. The outside world sends prompts in; the agent works on them (potentially across multiple LLM steps) and sends events back to any number of subscribers. Users control behaviour through lifecycle callbacks.

The agent owns the **turn** (a complete prompt-to-stop cycle). Messages commit to the tree as soon as they arrive (user prompt on turn start, assistant on step complete, tool-result user after executor, continuation user on `{:continue, ...}`). A `turn_start_node_id` cursor marks the user node that opened the turn; per-turn response slices (`messages`, `usage`) are derived by walking the active path from that cursor forward. On cancel or error, the active path rewinds to the pre-turn head — the turn's nodes stay on the tree as an abandoned branch, reachable via `navigate/2`.

### What lives here vs in `omni`

| This package (`omni_agent`) | Parent package (`omni`) |
|---|---|
| `Omni.Agent` — behaviour, `use` macro, public API | `Omni.stream_text/3`, `Omni.generate_text/3` |
| `Omni.Agent.Server` — GenServer internals | `Omni.Context`, `Omni.Message`, `Omni.Response` |
| `Omni.Agent.State` — public state struct | `Omni.Tool`, `Omni.Tool.Runner` |
| `Omni.Agent.Snapshot` — subscriber-facing point-in-time view | `Omni.Model`, `Omni.Usage` |
| `Omni.Agent.Tree` — branching conversation tree | `Omni.Content.*` content blocks |
| `Omni.Agent.Step` — LLM request task | Providers, dialects, streaming pipeline |
| `Omni.Agent.Executor` — tool execution task | |

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

- **`Omni.Agent.State`** — the public struct passed to all callbacks. Contains `id`, `model`, `system`, `tools`, `tree`, `opts`, `meta`, `private`, `status`, `step`.
- **`Omni.Agent.Server`** (internal) — wraps `State` and adds GenServer machinery: task refs, `turn_start_node_id` cursor, tool decision state, staged prompts, subscribers, partial streaming message. Never exposed to callbacks.

### Tree and turn cursor

The tree (`%Omni.Agent.Tree{}`) is an append-only branching structure of messages. Node ids are integers (`id = size + 1` on push). The tree tracks an **active path** — a cursor through the tree that `push_node` extends and `navigate/2` repositions. `Tree.messages/1` flattens the active path into a `[%Message{}]` list.

Every message commits to the tree as it's produced — there is no `pending_messages` buffer. During a turn, the server holds a `turn_start_node_id` cursor pointing at the user node that opened the turn. Per-turn response slices (for `:step`, `:continue`, `:stop`, `:cancelled` events) are derived by walking the active path from that cursor forward and summing node usages. On cancel or error, the active path rewinds to the parent of `turn_start_node_id`; the turn's nodes stay on the tree as an abandoned branch, reachable later via `navigate/2`.

LLM requests see `Tree.messages(state.tree)` as their full history — no merging, the tree is the source of truth.

### Agent loop

The agent loop operates at two levels:

- **Step** — a single LLM request-response. If the model calls tools, the agent handles them and makes another request.
- **Turn** — starts with `prompt/3`, ends with `{:stop, response}`. `handle_turn` fires when the model responds without executable tools. If it returns `{:continue, ...}`, the agent keeps working within the same turn (cursor stays fixed; continuation user message pushes under the same `turn_start_node_id`).

A single `evaluate_head/1` function drives the state machine: look up the message at `Tree.head(tree)` — user message → spawn step, assistant with tool uses → tool decision phase, assistant without → `handle_turn`.

The agent does **not** use `Omni.Loop` for tool execution — it calls `stream_text` with `max_steps: 1` so Loop never enters its tool loop. The agent manages tools itself via `handle_tool_use`/`handle_tool_result` callbacks, enabling per-tool approval gates and pause/resume.

### Tree navigation

- `navigate/2` — move the active path to any node (unrestricted; idle only).
- `regenerate/1` — re-run a step from the active head. At an assistant head, navigates to the parent (which must be a user message) and spawns a new step — the new assistant is pushed as a sibling of the previous. At a user head, spawns a step directly (retry-after-error path). Empty or invalid head returns `{:error, :invalid_head}`.

Regenerate from a specific node composes `navigate/2` + `regenerate/1` — there is no `regenerate/2`.

### Tool decision flow

When the model produces tool use blocks, all tool uses flow through `handle_tool_use/2`:

1. **Decision phase**: `handle_tool_use` called sequentially for each tool use — returns `{:execute, state}`, `{:reject, reason, state}`, `{:result, result, state}`, or `{:pause, reason, state}`
2. **Execution check**: if any approved tool lacks a handler → `handle_turn` with `stop_reason: :tool_use`
3. **Execution phase**: approved tools run in parallel via `Tool.Runner.run/3`, results (executed + rejected + provided) passed to `handle_tool_result`

### Subscribers

Any process can call `Omni.Agent.subscribe/1` to receive events as `{:agent, pid, type, data}` messages. Subscribers are monitored — crashed ones are reaped via `Process.monitor`. `subscribe/1` returns `{:ok, %Omni.Agent.Snapshot{}}` — a point-in-time view including `partial_message` (content blocks streamed so far in the in-flight assistant) and `paused` (`{reason, tool_use}` while awaiting a tool decision) — so late joiners can render current state without missing earlier events.

## Module Layout

```
lib/omni/
├── agent.ex                    # Public module: behaviour, use macro, callback defaults, API
├── agent/
│   ├── state.ex                # Public state struct passed to callbacks
│   ├── snapshot.ex             # Point-in-time view returned by subscribe/1
│   ├── tree.ex                 # Branching conversation tree (pure data)
│   ├── server.ex               # Internal GenServer (@moduledoc false)
│   ├── step.ex                 # Step process: streams LLM request (@moduledoc false)
│   └── executor.ex             # Executor process: parallel tool execution (@moduledoc false)
```

## Conventions

- The term is "tool use", not "tool call" (aligns with Anthropic's API, consistent with `omni`).
- Agent statuses: `:idle`, `:running`, `:paused`. Status determines which API calls are valid. `navigate/2`, `regenerate/1`, and `set_state/2,3` are idle-only.
- All callbacks are optional with `defoverridable` defaults. Users implement only what they need.
- `set_state/2` (keyword list, replaces by key, atomic) and `set_state/3` (single field + value or function). Settable fields: `:model`, `:system`, `:tools`, `:opts`, `:meta`. `:tree` is deliberately not settable — pass it at startup for hydration or compose `navigate`/`regenerate` at runtime.
- Events: `:message` fires on every tree append (flat-consumer path); `:node` fires alongside with `%{id, parent_id, message, usage}` (tree-aware consumers); `:tree` fires on non-incremental changes (navigate, regenerate, cancel/error rewind). `:step` carries the per-step `%Response{}`. `:stop`, `:continue`, and `:cancelled` carry a `%Response{}` with `messages` — the turn's slice derived from the cursor. `:error` carries the bare error reason term.
- The agent has no `session_id` or built-in persistence — session identity and storage are application concerns (persistence arrives in Phase 3 of the durable-agents work). The `{:stop, response}` event carries enough context (`messages`, `usage`) for external listeners to persist.
- `prompt/3` behaviour depends on status: idle → start turn, running/paused → stage for next turn boundary (steering).
- On error or cancel, the active path rewinds to the pre-turn head and the agent goes to `:idle`. The turn's nodes stay on the tree as an abandoned branch (reachable via `navigate/2`). The app can prompt again immediately.

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

- **`context/design.md`** — Full architecture reference covering: relationship to `omni`, public API (`prompt`, `set_state`), lifecycle callbacks (`init`, `handle_tool_use`, `handle_tool_result`, `handle_turn`, `handle_error`, `terminate`), process model (Step/Executor/Tool Tasks), pause/resume, prompt queuing/steering, the completion tool pattern, and the evaluate_head state machine.
- **`context/durable_agents.md`** — Multi-phase plan for adding durability, multi-subscriber pub-sub, branching tree, navigation, and persistence. Phases 1 and 2 are complete (subscribers + snapshot + state decomposition; tree + per-message commit + navigate/regenerate + cancel/error rewind). Phases 3 and 4 add Store/Supervisor/Registry and `:config` events.
