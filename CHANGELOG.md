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
- **`omni` dependency bumped to `~> 1.3.0`** — hex release containing `Omni.Codec`, which `Omni.Session.Store.FileSystem` uses for serialising messages, usage, and opts. Replaces the local path dep used during parallel development.
- **Agent status `:running` renamed to `:busy`** — status vocabulary is now `:idle | :busy | :paused`. Status-gated operations return the current status atom as their error reason: `set_state` / `set_agent` / `add_tool` / `remove_tool` / `navigate` / `branch` return `{:error, :busy | :paused}` instead of `{:error, :running}` / `{:error, :not_idle}`; `resume` returns `{:error, :idle | :busy}` instead of `{:error, :not_paused}`. `cancel` still returns `{:error, :idle}`.

### Added

- **`:private` start option** — initial private map, previously only settable via `init/1`.
- **Messages invariant** — `set_state(:messages, ...)` and the state returned from `init/1` are validated to be empty or end with an `:assistant` message containing no `%ToolUse{}` blocks. Violations return `{:error, :invalid_messages}`.
- **`:message` event** — `{:agent, pid, :message, %Message{}}` emitted each time a message is appended to pending: the initial user message, each assistant response after streaming, the tool-result user message, and the continuation user message. Fires after the streaming deltas for that message.
- **`:state` event** — `{:agent, pid, :state, %State{}}` emitted after every successful `set_state/2,3` call, carrying the full new state.
- **`Omni.Session.Tree`** — pure-data branching message tree used by the in-development `Omni.Session`. `%Tree{nodes, path, cursors}` with auto-assigned integer node IDs, append-only semantics, cursor-guided active path, `push/3`/`push_node/3`/`navigate/2`/`extend/1` for mutation (including `navigate(tree, nil)` to clear the path for multi-root trees), structural queries (`children/2`, `siblings/2`, `roots/1`, `path_to/2`, `get_node/2`, `get_message/2`), derived views (`messages/1`, `usage/1`, `head/1`, `size/1`), `new/1` hydration constructor, and `Enumerable` over the active path.
- **`Omni.Session.Store`** — persistence contract for the in-development `Omni.Session`. Single module combining the adapter behaviour (`save_tree`, `save_state`, `load`, `list`, `delete`) and dispatch functions. Canonical store shape is `{module, keyword()}`; `list/2` mandates `:limit`/`:offset` and sorts by `updated_at` descending. Session-owned `state_map` is a prescribed four-key schema (`:model`, `:system`, `:opts`, `:title`) with overwrite semantics. No global Application-env fallback — applications wrap the store tuple in their own helper (moduledoc documents the idiomatic pattern).
- **`Omni.Session.Store.FileSystem`** — reference filesystem adapter. Each session lives in `<base_path>/<id>/` with `nodes.jsonl` (append-only when `save_tree/4` is called with a `:new_node_ids` hint; full rewrite otherwise) and `session.json` (single merged file written by both `save_tree` and `save_state` on disjoint keys). Uses `Omni.Codec` for messages/usage/opts; `model` serialised as plain `[provider, id]` JSON for inspectability; `system`/`title` as plain JSON strings; timestamps as ISO8601. Adapter config requires `:base_path`; no default.
- **`Omni.Session`** — GenServer wrapping a linked `Omni.Agent` with session identity, a branching message tree, pluggable storage, and pub/sub. `start_link/1` supports `new: :auto | binary()` and `load: binary()` modes; load-mode resolution has persisted model winning with start-opt fallback, start-opt `system`/`opts` winning over persisted, tree as the sole message source, and `agent: [messages: _]` rejected on `:new` / silently ignored on `:load`. Auto-generated IDs use `:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`. Agent events are forwarded re-tagged as `{:session, pid, type, payload}`. Turn commits push segment messages into the tree (per-segment usage attached to the segment's last assistant) and synchronously persist via `Store.save_tree/4` with `:new_node_ids`; event order is `:turn → :tree → :store {:saved, :tree}`. Agent `:state` events drive `save_state` when the persistable subset (`model`, `system`, `opts`, `title`) changes — tool and private mutations don't trigger writes. Store failures emit `:store {:error, op, reason}`; the session never halts on store errors. Pub/sub with per-subscriber monitors; `subscribe/1,2` returns an atomic `%Omni.Session.Snapshot{id, title, tree, agent}`. Turn passthroughs (`prompt/2,3`, `cancel/1`, `resume/2`), inspection (`get_agent/1,2`, `get_tree/1`, `get_title/1`, `get_snapshot/1`), `set_agent/2,3` delegation to `Agent.set_state/2,3`, and `stop/1` graceful shutdown that stops the linked Agent. Agent crashes cascade to the Session via link (no `trap_exit`).
- **`Omni.Session.Snapshot`** — `%Snapshot{id, title, tree, agent}`, bundling committed tree state with an `%Omni.Agent.Snapshot{}` for the in-flight slice.
- **Session navigation** — `Omni.Session.navigate/2` sets the active tree path by walking parent pointers (accepts `nil` to clear for multi-root trees), updates cursors, resyncs the Agent via `set_state(messages: _)`, and emits `:tree` with empty `new_nodes`. Idle-only.
- **`Omni.Session.branch/2,3`** — a single primitive for tree branching. `branch(user_id)` regenerates the turn rooted at the target user message (new assistant response, same content); internally it navigates tree path to the user, sets agent messages to the user's parent path, prompts with the user's content, and drops the leading duplicate user from the resulting `:turn` response before pushing the rest as children of the target. `branch(assistant_id, content)` extends from the target assistant with a new user message — the "edit next user" operation. `branch(nil, content)` is the sugared form of `navigate(nil)` + `prompt(content)`, creating a new disjoint root. Idle-only; role-mismatched targets return `{:error, :not_user_node}` or `{:error, :not_assistant_node}`. Applications build higher-level edit/regen UX on top.
- **`Omni.Session.set_title/2`** — updates the title, emits `:title`, and flows through the persistable-subset change-detection path to trigger `save_state` (no write on a same-value set). Not idle-gated.
- **`Omni.Session.add_tool/2` / `remove_tool/2`** — convenience helpers over `set_agent(:tools, _)`. Tools remain non-persisted; these operations don't trigger `save_state`.
- **`:title` event** — `{:session, pid, :title, title | nil}` emitted after `set_title/2`.
- **`:tree` events on all tree mutations** — navigation and branch initiation emit `:tree` with empty `new_nodes` (tree path changed, no new nodes); turn commits emit `:tree` with the newly-added node ids as before.
- **Agent `:status` event** — `{:agent, pid, :status, :idle | :busy | :paused}` emitted on every status transition. Fires at the state-write site, so `:status` always precedes its derived event (`:turn`, `:cancelled`, `:error`, `:pause`). Idempotent transitions (already-idle → idle) don't emit.
- **Session subscribe modes** — `subscribe/1,2,3` accepts `mode: :controller | :observer` (default `:controller`). Subscriptions are idempotent per pid; a second call with a different mode updates the mode in place. Start-opt `subscribers:` accepts bare pids (implicit `:controller`) or `{pid, mode}` tuples. Session forwards Agent `:status` events verbatim as `{:session, pid, :status, s}`.
- **`:idle_shutdown_after` Session start option** — `non_neg_integer()` (ms) or `nil`. When set to a positive integer, the session self-shuts-down when the controller count drops to zero and the agent is idle. Evaluated only on transitions — never at init; a busy/paused transition cancels any armed timer; a new controller (or upgrade from observer to controller) cancels too. Default `nil` keeps standalone Session behaviour unchanged.
- **`Omni.Session.Manager`** — `use`-pattern Supervisor for multi-session lifecycle management. Apps define their own module (`defmodule MyApp.Sessions, do: use Omni.Session.Manager`) and drop it into a supervision tree. Owns a Registry (id → pid) and a DynamicSupervisor (`:temporary` children); Manager config (store, idle_shutdown_after) lives in `:persistent_term` keyed by the Manager module so it survives a Registry restart under `:one_for_one`. Required `:store`; `:idle_shutdown_after` defaults to 300_000 ms with `nil` to disable (per-Manager or per-call override). Public API: `create/2` (explicit-`:id` collision check against the Registry and the store), `open/3` with tagged `{:ok, pid, :started | :existing}` return — start-time opts (`:agent`, `:title`, `:idle_shutdown_after`, `:subscribers`) apply on `:started`, are silently dropped on `:existing` (callers who need fresh config `close` + `open`), `close/2` (idempotent `Session.stop/1`), `delete/2` (close-then-store-delete), `whereis/2`, `list/2`. Caller is auto-subscribed as `:controller` by default (opt out with `subscribe: false`); Manager strips `:subscribe` before forwarding to `Session.start_link/1` and explicitly injects `subscribers: [caller]` — Session's own `subscribe: true` sugar would otherwise subscribe the DynamicSupervisor and permanently pin every session against idle-shutdown. Rejects Manager-owned opts (`:store`, `:name`, `:new`, `:load`) with `{:error, {:invalid_opt, key}}`. `Omni.Session.Manager.*` functions remain callable with an explicit module-name atom as the first argument.
- **`Omni.Session.Store.exists?/2`** — new callback and dispatch. Returns `true` when the adapter holds persisted state for an id. FileSystem adapter checks for the presence of `session.json`. Used by `Session.start_link(new: binary)` to detect duplicate-id collisions before creating a conflicting session.
- **Session `new: <binary>` duplicate-id check** — `Session.start_link(new: "explicit-id", ...)` now returns `{:error, :already_exists}` when the id is already persisted in the store. `new: :auto` skips the check (128-bit entropy makes collision effectively impossible).
- **`Omni.Session.Manager.Tracker` and Manager-level pub/sub** — internal GenServer added as the third Manager supervisor child. Observes every running session as `:observer` (so the tracker subscription does not pin lifetimes) and maintains an in-memory projection `%{id => %{id, title, status, pid}}`. New public surface on the Manager: `list_open/1` (synchronous snapshot), and `subscribe/1` / `unsubscribe/1` for a live cross-session feed with atomic snapshot on subscribe. Events are tagged `{:manager, ManagerModule, event, payload}` where the second element is the Manager module atom the caller already holds — no ceremony around pids. Event set: `:session_added` (`%{id, title, status, pid}` on create and open `:started`, suppressed on open `:existing`), `:session_status` (`%{id, status}`), `:session_title` (`%{id, title}`), `:session_removed` (`%{id}` on close, delete, crash, and idle-shutdown). `Manager.create/2` and `Manager.open/3` synchronously hand the pid off to the Tracker before returning, so every pid a caller sees is already tracked; the hand-off is idempotent for already-tracked ids. The `use` macro grows `list_open/0`, `subscribe/0`, `unsubscribe/0` zero-arity delegates. Tracker crash-recovers by enumerating the Manager's Registry on restart and re-subscribing to every running session; Manager-level subscribers from before the crash are dropped and must re-subscribe (documented).

### Fixed

- **Per-segment `turn_usage` in the Agent** — `commit_segment/1` now resets `turn_usage` alongside `turn_messages`, so each `:turn` event's `response.usage` reflects only that segment rather than the cumulative turn. Prevents double-counting across multi-segment (`{:continue, _}`) turns for any subscriber — including `Omni.Session`, which attaches each segment's usage to its last assistant node in the persisted tree.
- **Tool-result ordering in the Agent** — when an assistant message contained multiple `%ToolUse{}` blocks, the tool-result user message the agent appended could come out in the wrong order. Two bugs compounded: `provided_results` accumulated forward then got spuriously reversed at merge time, and the three decision-type accumulators were concatenated as `rejected ++ provided ++ executed` — losing any interleaving across decision types (`[first→:result, second→:reject]` came out as `[second_rejected, first_provided]`). Replaced the type-keyed accumulators with a single `tool_use_id`-keyed map plus the original ordered `tool_uses` list; results are now reassembled in tool-use order, insensitive to decision type, sync-vs-resume arrival order, and the executor's parallel completion order.

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
