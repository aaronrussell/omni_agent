# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Structured output not propagated to response** — when using the `output:` option with a schema, the parsed `output` from the LLM response was not being set on the `Response` delivered with `:done` and `:continue` events. The output is now correctly carried through from the underlying step response.

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

[Unreleased]: https://github.com/aaronrussell/omni_agent/compare/v0.1.0...HEAD
[1.2.0]: https://github.com/aaronrussell/omni_agent/releases/tag/v0.1.0
