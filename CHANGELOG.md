# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Flat `%Omni.Agent.State{}`** — nested `%Context{}` replaced with top-level `:system`, `:messages`, `:tools` fields. `:meta` removed (deferred to future `Omni.Session`).
- **`init/1` shape** — now receives the fully-resolved `%State{}` and returns `{:ok, state} | {:error, term}`, enabling callbacks to set any field (including defaults for `:system`, `:tools`, etc.). The old opts-in/private-out shape is gone.
- **`set_state` keys** — settable fields are now `:model`, `:system`, `:messages`, `:tools`, `:opts`. `:context` and `:meta` are gone; `:private` remains callback-owned.
- **`:stop` and `:continue` events collapsed into `:turn`** — now `{:agent, pid, :turn, {:stop, response}}` and `{:agent, pid, :turn, {:continue, response}}`. Both variants commit pending messages to `state.messages`, so every segment boundary is a real commit point.
- **Per-step / per-segment response messages** — `:step.response.messages` contains only that step's messages (assistant, plus preceding tool-result user message when applicable). `:turn.response.messages` contains only that segment's committed messages, not the whole turn's.

### Added

- **`:private` start option** — initial private map, previously only settable via `init/1`.
- **Messages invariant** — `set_state(:messages, ...)` and the state returned from `init/1` are validated to be empty or end with an `:assistant` message containing no `%ToolUse{}` blocks. Violations return `{:error, :invalid_messages}`.
- **`:message` event** — `{:agent, pid, :message, %Message{}}` emitted each time a message is appended to pending: the initial user message, each assistant response after streaming, the tool-result user message, and the continuation user message. Fires after the streaming deltas for that message.
- **`:state` event** — `{:agent, pid, :state, %State{}}` emitted after every successful `set_state/2,3` call, carrying the full new state.
- **`Omni.Session.Tree`** — pure-data branching message tree used by the in-development `Omni.Session`. `%Tree{nodes, path, cursors}` with auto-assigned integer node IDs, append-only semantics, cursor-guided active path, `push/3`/`push_node/3`/`navigate/2`/`extend/1` for mutation (including `navigate(tree, nil)` to clear the path for multi-root trees), structural queries (`children/2`, `siblings/2`, `roots/1`, `path_to/2`, `get_node/2`, `get_message/2`), derived views (`messages/1`, `usage/1`, `head/1`, `size/1`), `new/1` hydration constructor, and `Enumerable` over the active path.
- **`Omni.Session.Store`** — persistence contract for the in-development `Omni.Session`. Single module combining the adapter behaviour (`save_tree`, `save_state`, `load`, `list`, `delete`) and dispatch functions. Canonical store shape is `{module, keyword()}`; `list/2` mandates `:limit`/`:offset` and sorts by `updated_at` descending. Session-owned `state_map` is a prescribed four-key schema (`:model`, `:system`, `:opts`, `:title`) with overwrite semantics. No global Application-env fallback — applications wrap the store tuple in their own helper (moduledoc documents the idiomatic pattern).
- **`Omni.Session.Store.FileSystem`** — reference filesystem adapter. Each session lives in `<base_path>/<id>/` with `nodes.jsonl` (append-only when `save_tree/4` is called with a `:new_node_ids` hint; full rewrite otherwise) and `session.json` (single merged file written by both `save_tree` and `save_state` on disjoint keys). Uses `Omni.Codec` for messages/usage/opts; `model` serialised as plain `[provider, id]` JSON for inspectability; `system`/`title` as plain JSON strings; timestamps as ISO8601. Adapter config requires `:base_path`; no default.

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
