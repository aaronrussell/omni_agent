# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Multi-subscriber pub-sub.** `Omni.Agent.subscribe/1` returns `{:ok, %Snapshot{}}` and registers the caller; any number of processes can subscribe, crashed ones reaped via `Process.monitor`. `unsubscribe/1` removes a subscriber.
- **`%Omni.Agent.Snapshot{}`** — point-in-time view including `:partial_message` (content blocks streamed so far) and `:paused` (`{reason, tool_use}` when awaiting a tool decision), so late joiners catch up mid-turn or while paused without missing earlier events.
- **`:message` event** — `{:agent, pid, :message, %Message{}}` fires when each message is appended during a turn (user prompts, assistant responses, tool-result user messages).
- **Decomposed `%Omni.Agent.State{}`** — new `:id`, `:system`, `:tools`, `:tree` fields replace the old `:context` field. `:tree` is a flat `[%Message{}]` in this release; a future version introduces a branching tree struct.

### Changed

- **Breaking: implicit listener replaced by explicit subscription.** `Omni.Agent.listen/2` and the `:listener` start opt are removed; callers must call `subscribe/1` explicitly. The first-prompt-caller-auto-registers behaviour is gone.
- **Breaking: `:context` removed throughout.** `State.context`, the `:context` start opt, and `set_state(context: ...)` no longer exist. Use `:system`, `:tools`, and `:tree` (or the temporary `:messages` alias) individually; read via `get_state(agent, :system)` etc. Legacy `:listener` / `:context` start opts return `{:error, {:invalid_opt, key}}` to make migration visible.

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
