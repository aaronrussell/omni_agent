# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

This release introduces the **Session** and **Manager** layers on top of `Omni.Agent` — conversation lifetime, a branching message tree, pluggable persistence, pub/sub, and multi-session supervision. Agent itself also picks up new lifecycle events and a flatter state shape.

### Added

- **`Omni.Session`** — GenServer wrapping a linked `Omni.Agent` with session identity, a branching message tree, pluggable storage, and pub/sub. `start_link/1` supports `new: :auto | binary()` and `load: binary()` modes; the public API covers turn passthroughs, tree navigation, branching (regen / edit-next-user / new-root), titles, subscribers with `:controller | :observer` modes, and optional idle-shutdown.
- **`Omni.Session.Manager`** — `use`-pattern Supervisor for multi-session lifecycle. Apps define their own Manager module (`use Omni.Session.Manager`) and drop it into a supervision tree. Handles create / open / close / delete, `list_open`, and per-Manager pub/sub over a live cross-session feed of session status, title, and lifecycle events.
- **`Omni.Session.Store`** — persistence contract (behaviour + dispatch). `Omni.Session.Store.FileSystem` ships as the reference adapter; sessions live in `<base_path>/<id>/` as `nodes.jsonl` + `session.json`.
- **`Omni.Session.Tree`** — pure-data branching message tree with auto-assigned node IDs, navigation, and `Enumerable` over the active path. The data structure backing Session's conversation state.
- **New Agent events** — `:message` (per message appended), `:state` (per `set_state` mutation), and `:status` (per transition, fires before its derived event). Session forwards all three re-tagged.

### Changed

- **Agent `init/1` shape** — now receives the fully-resolved `%State{}` and returns `{:ok, state} | {:error, term}`. Callbacks can set any field, including defaults for `:system` and `:tools`.
- **Agent status `:running` renamed to `:busy`** — vocabulary is now `:idle | :busy | :paused`. Status-gated operations return the current status atom as their error reason (e.g. `{:error, :busy}`).
- **Agent `:stop` and `:continue` events collapsed into `:turn`** — now `{:agent, pid, :turn, {:stop | :continue, response}}`. Both variants commit pending messages to `state.messages`, so every `:turn` event is a reliable commit point.
- **Per-step and per-turn response messages** — `:step.response` carries only that step's messages; `:turn.response` carries only that turn's committed messages and usage. Prevents double-counting for subscribers that persist per-turn.
- **`omni` dependency bumped to `~> 1.3.0`** — hex release containing `Omni.Codec`, used by `FileSystem` to serialise messages, usage, and opts.

### Fixed

- **`turn_usage` reset across continuations** — `turn_usage` wasn't cleared when a turn ended with `:continue`, so the next turn's `:turn` event double-counted usage.
- **Tool-result ordering** — when an assistant message contained multiple `%ToolUse{}` blocks, the resulting tool-result user message could come out of order. Results are now reassembled in tool-use order, insensitive to decision type and to sync-vs-resume and parallel-execution arrival order.

## [0.2.0] - 2026-04-02

### Added

- **`:step` event** — `{:agent, pid, :step, %Response{}}` emitted after each LLM request-response completes, giving consumers per-step visibility into multi-step turns.

### Changed

- **`:done` event renamed to `:stop`** — `{:agent, pid, :done, response}` is now `{:agent, pid, :stop, response}`. The `:continue` event retains the same shape. Both event names now directly mirror the `handle_turn/2` callback return values (`:stop` or `:continue`).

### Fixed

- **Structured output not propagated to response** — when using the `output:` option with a schema, the parsed `output` from the LLM response was not being set on the `Response` delivered with `:stop` events. The output is now correctly carried through from the underlying step response.

## [0.1.0] - 2026-03-24

Initial release of Omni Agent as a standalone package, extracted from the `omni` package where it previously lived as `Omni.Agent`. The agent system was separated to allow the stateless LLM API layer (`omni`) to remain stable while the agent layer continues to evolve through rapid experimentation.

The agent internals were simplified — the loop hierarchy was flattened from three levels (round > turn > step) to two (turn > step), several callbacks were renamed for clarity, and the tool use flow was unified so that every tool use passes through `handle_tool_use` regardless of whether it has a handler.

### Added

- **`Omni.Agent`** — GenServer-based building block for stateful, multi-turn LLM conversations with lifecycle callbacks, tool approval with pause/resume, and prompt queuing/steering.
- **`Omni.Agent.State`** — public state struct passed to all callbacks.

### Changed (relative to `Omni.Agent` in `omni`)

- **Two-level loop model** — "round" concept removed. A **turn** (prompt to done) contains one or more **steps** (LLM request-response cycles). Continuations stay within the same turn.
- **`handle_stop`** renamed to **`handle_turn`** — fires when the model completes without executable tools.
- **`handle_tool_call`** renamed to **`handle_tool_use`** — aligns with `%ToolUse{}` and Anthropic terminology.
- **`:turn` event** renamed to **`:continue` event** — avoids collision with "turn" as the top-level concept.
- **Unified tool use flow** — all tool uses flow through `handle_tool_use` with four return variants (`:execute`, `:reject`, `:result`, `:pause`). No more `has_executable_tools?` all-or-nothing check.

---

[Unreleased]: https://github.com/aaronrussell/omni_agent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/aaronrussell/omni_agent/releases/tag/v0.2.0
[0.1.0]: https://github.com/aaronrussell/omni_agent/releases/tag/v0.1.0
