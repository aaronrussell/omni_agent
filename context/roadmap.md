# Roadmap

A sequence of phases for the current direction of work. Each phase leaves
the system in a working, tested state and can land as its own commit or PR.

Detailed design specs live alongside this file (e.g. `agent-redesign.md`
for the Agent refactor, `session-design.md` for the Session build-out).
This roadmap is an index, not a spec.

---

## Completed phases

### Phase 1 — Agent: state shape and `init/1` *(done)*

**Spec:** `agent-redesign.md` (State shape, Validation, Callbacks).

Flattened `%State{}` (dropped nested `%Context{}` and `:meta`), moved
`init/1` to a state-in/state-out shape, added `:private` start option,
and introduced the `set_state(:messages, _)` validation rule (list must
be empty or end on an assistant message with no ToolUse blocks).

### Phase 2 — Agent: event model *(done)*

**Spec:** `agent-redesign.md` (Events, Turn lifecycle).

Redesigned the event catalogue: added per-message `:message` events,
collapsed `:stop`/`:continue` into `:turn {:stop, _}` / `:turn {:continue, _}`
with commit-on-every-segment semantics, added `:state` events for
`set_state` mutations, and aligned `:step` / `:turn` response payloads
with per-segment semantics.

### Phase 3 — Agent: pub/sub and snapshot *(done)*

**Spec:** `agent-redesign.md` (Pub/sub, Snapshot).

Replaced the single-listener model with native multi-subscriber pub/sub
(`subscribe/1,2`, `unsubscribe/1,2`), added atomic snapshot-on-subscribe
via `%Omni.Agent.Snapshot{}`, and retired the `listener` concept.

### Phase 4 — Session: design *(done)*

**Spec:** `session-design.md`.

Design exercise producing the full spec for `Omni.Session`: storage
adapter shape, tree schema, persistence triggers, load-mode resolution,
public API, events, snapshot, navigation/regeneration mechanics, and
parked follow-up work (Session Manager, idle-timeout, etc.). Phases 5–8
below derive directly from this spec.

### Phase 5 — Session: Tree module *(done)*

**Spec:** `session-design.md` (Tree schema).

Implemented `Omni.Session.Tree` as a pure-data module: `%Tree{nodes,
path, cursors}` with auto-assigned integer node IDs, append-only
semantics, and cursor-guided active path. Mutation via `push/3`,
`push_node/3`, `navigate/2` (including `nil` to clear the path for
multi-root trees), and `extend/1`. Structural queries (`children`,
`siblings`, `roots`, `path_to`, `get_node`, `get_message`), derived
views (`messages`, `usage`, `head`, `size`), `new/1` hydration
constructor, and `Enumerable` over the active path.

### Phase 6 — Session: Store behaviour + FileSystem adapter *(done)*

**Spec:** `session-design.md` (Storage).

Shipped `Omni.Session.Store` as a single module combining the adapter
behaviour (`save_tree`, `save_state`, `load`, `list`, `delete`) and the
dispatch functions. Canonical store shape is `{module, keyword()}` —
no struct, no global Application-env fallback; apps wrap their own
helper around the tuple. `list/2` mandates `:limit` and `:offset`;
Session-owned `state_map` is the prescribed four-key schema
(`:model`, `:system`, `:opts`, `:title`) with overwrite semantics.
Reference adapter `Omni.Session.Store.FileSystem` persists each session
to a directory with `nodes.jsonl` (append-only via `:new_node_ids`
hint) and `session.json` (disjoint-keys merge between `save_tree` and
`save_state`), using `Omni.Codec` for messages/usage/opts. Switched
the `omni` dep to a path dep to consume `Omni.Codec` ahead of its
release.

### Phase 7 — Session: core GenServer *(done)*

**Spec:** `session-design.md` (State shape, Lifecycle, Events, Snapshot,
Pub/sub, Load-mode resolution).

Shipped `Omni.Session` as a single module wrapping a linked `Omni.Agent`.
Supports `new: :auto | binary()` and `load: binary()` start modes with
load-mode resolution (persisted model wins, start-opt system/opts win,
tree is the sole message source). Forwards agent events re-tagged as
`{:session, pid, type, payload}`. Turn commits push segment messages
into the tree (per-segment usage attached to the segment's last
assistant) and synchronously `save_tree` via the store's adapter, with
ordering `:turn → :tree → :store {:saved, :tree}`. Agent `:state`
events diff the persistable subset (`model`, `system`, `opts`, `title`)
against `last_persisted_state` — changes trigger `save_state`, tool
and private mutations don't. Pub/sub with per-subscriber monitors and
atomic `Session.Snapshot{id, title, tree, agent}`. Turn passthroughs
(`prompt`, `cancel`, `resume`), inspection (`get_agent`, `get_tree`,
`get_title`, `get_snapshot`), and `set_agent/2,3` (pulled forward from
Phase 8 to keep change-detection testable). `stop/1` stops the linked
Agent. Agent crash cascades to Session via link (no `trap_exit`).
Bundled a small Agent fix: `commit_segment/1` now resets `turn_usage`
per segment so each `:turn` event's `response.usage` is segment-scoped
— multi-segment turns no longer double-count usage in the persisted
tree.

### Phase 8 — Session: navigation, branching, mutation APIs *(done)*

**Spec:** `session-design.md` (Navigation & branching, Public API
§ Mutation).

Shipped the full mutation surface on `Omni.Session`. `navigate/2` sets
the active tree path by parent-walk (accepts `nil` to clear), updates
cursors, resyncs the Agent via `set_state(messages: _)`, and emits
`:tree` with empty `new_nodes`. A single `branch/2,3` primitive covers
all branching: `branch(user_id)` regenerates a turn (navigate to the
user, set agent messages to the user's parent path, prompt with the
user's content; on the first `:turn` commit, drop the duplicate
leading user via an internal `regen_source` flag); `branch(assistant_id,
content)` edits the next user message (navigate to the assistant,
prompt with new content, all turn messages append as children);
`branch(nil, content)` creates a disjoint new root as the atomic
equivalent of `navigate(nil)` + `prompt(content)`. All navigation and
branching is idle-only — `{:error, :not_idle}` when a turn is in
flight. `set_title/2` updates the title, emits `:title`, and flows
through the same change-detection path as agent config to trigger
`save_state`. `add_tool/2` / `remove_tool/2` are thin wrappers over
`set_agent(:tools, _)`; tools remain non-persisted. `:tree` events
fire on every tree mutation (turn commits, navigation, branch
initiation). Tree path and agent messages are deliberately out of sync
during an in-flight regen (tree ends on the user; agent ends on the
user's parent), resolved at turn commit; cancelled or errored regens
clear `regen_source` without tree mutation.

### Phase 9a — Agent and Session foundations for Manager *(done)*

**Spec:** `manager-design.md` (Agent changes, Session changes).

Added the Agent `:status` event (`{:agent, pid, :status, :idle |
:running | :paused}`) fired on every status transition, emitted at the
state-write site so `:status` precedes its derived event
(`:turn`/`:cancelled`/`:error`/`:pause`); idempotent idle→idle resets
don't emit. Unified Session subscriber state under a `subscribers`
MapSet (broadcast set) with a `controllers` MapSet subset (keep-alive
set), and unified `subscribe/1,2,3` under a `mode: :controller |
:observer` option — per-pid idempotent, mode updates in place; bare-pid
arity kept for back-compat; start-opt `subscribers:` accepts `pid |
{pid, mode}`. Session forwards Agent `:status` verbatim and caches
`agent_status` internally. New `:idle_shutdown_after` start option
(`nil | non_neg_integer()`, default `nil`) schedules a cancellable
shutdown timer when controllers drop to zero with the agent idle —
evaluated only on transitions (unsubscribe, mode change, controller
DOWN, `:status :idle`), never at init; running/paused transitions
cancel any armed timer. Standalone Session behaviour is unchanged when
the option is unset.

### Phase 9b — Manager core *(done)*

**Spec:** `manager-design.md` (Manager as Supervisor, Public API,
The `use` pattern, Configuration).

Shipped `Omni.Session.Manager` as a `use`-pattern Supervisor that owns
a Registry (id → pid) and a DynamicSupervisor (per-session lifetimes,
`:temporary` children). Config lives in `:persistent_term` keyed by
the Manager module — resilient to Registry restart under
`:one_for_one`. Required `:store`; `:idle_shutdown_after` defaults to
300_000 ms with `nil` to disable (per-Manager or per-call). Public
API: `create/2` (with `:id` collision check against store + running
Registry), `open/3` with tagged `{:ok, :started | :existing, pid}`
return (start-time opts applied on `:started`, silently dropped on
`:existing` — callers who need fresh config `close` + `open`),
`close/2` (idempotent `Session.stop/1`), `delete/2` (close-then-store
delete), `whereis/2`, `list/2`. Caller is auto-subscribed as
`:controller` by default (opt out with `subscribe: false`); Manager
strips `:subscribe` before forwarding to `Session.start_link` and
explicitly injects `subscribers: [caller]`, because Session's own
`subscribe: true` sugar would subscribe the DynamicSupervisor and
permanently pin sessions against idle-shutdown. Bundled two small
prerequisites: a new `Store.exists?/2` callback (plus FileSystem
implementation) for the duplicate-id check, and a Session `init/1`
guard that returns `{:error, :already_exists}` when `new: <binary>`
collides with persisted state (`new: :auto` skips the check).

### Phase 9c — Tracker and Manager-level pub/sub *(done)*

**Spec:** `manager-design.md` (The Tracker, Events, Public API §
list_running / subscribe).

Shipped `Omni.Session.Manager.Tracker` as the third child of the
Manager supervisor — an internal GenServer that observes every running
session as `:observer` (lifetime-neutral) and maintains
`%{id => %{id, title, status, pid}}`. `Manager.create/2` and
`Manager.open/3` synchronously hand the pid off to `Tracker.add/3`
before returning, so every pid a caller sees is already tracked;
hand-off is idempotent on the `:existing` branch of `open`. New public
API on the Manager: `list_running/1` (synchronous snapshot) and
`subscribe/1` / `unsubscribe/1` (atomic snapshot on subscribe + live
tail). Events are tagged `{:manager, ManagerModule, event, payload}`
(module atom, not Tracker pid — the caller already holds the module,
and it pattern-matches on a compile-time-known value): `:session_added`
on create / `open :started` (suppressed on `:existing`),
`:session_status` on Agent status transitions, `:session_title` on
`set_title`, `:session_removed` on close / delete / crash /
idle-shutdown. `use` macro grows `list_running/0`, `subscribe/0`,
`unsubscribe/0` delegates. Tracker crash-recovers by enumerating the
Manager's Registry on restart and re-subscribing silently; Manager-level
subscribers from before the crash are dropped and must re-subscribe
(documented).

---

## Upcoming phases

_(none open)_

---

## Beyond phase 9

Candidates for follow-up work:

- **`:data` field on Agent state** — app-defined per-session metadata
  slot on Agent rather than Session. Deferred until a concrete consumer
  surfaces. (Parked in `session-design.md`.)
- **Title auto-generation helpers** — `auto_title:` start option as sugar
  over the subscribe-and-set pattern. (Parked in `session-design.md`.)
- **Retry / write-behind queue** for high-latency store adapters.
  (Parked in `session-design.md`.)
- **Persistent event log / replay** — subscribers resuming from a
  sequence number after process restart. (Parked in `session-design.md`.)
- **Agent init-triggers-initial-prompt** — extended `init/1` return or
  `:prompt` start option. (Parked in `agent-redesign.md`.)
- **Distributed Manager** — cross-node Registry, cross-node Tracker
  pub/sub. (Parked in `manager-design.md`.)
- **Manager-level telemetry** — observability events at Manager
  operation boundaries. (Parked in `manager-design.md`.)
- **Per-session Tracker metadata** — app-attachable fields on the
  Tracker's session map. (Parked in `manager-design.md`.)

These are deferred until concrete need has been demonstrated.
