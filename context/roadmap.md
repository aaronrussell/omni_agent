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

---

## Phase 8 — Session: navigation, regen, mutation APIs

**Status:** Not started.

**Spec:** `session-design.md` (Navigation & regeneration, Public API
§ Mutation).

**Goal:** Branching navigation, regeneration semantics, and the full
mutation surface.

**Key work:**

- `navigate/2`: set active path via parent-walk; update cursors;
  `Agent.set_state(messages: ...)`; emit `:tree` with empty `new_nodes`.
- `branch/3`: navigate + prompt, atomically surfaced as a single call.
- `regen/2`: targets an assistant node; navigates to parent-of-user;
  sets Agent messages; re-prompts with the original user content;
  uses `regen_target` flag to drop the duplicated user message from the
  resulting `:turn` response before tree commit.
- `set_title/2`: updates title, triggers `save_state` via digest path,
  emits `:title` event.
- `add_tool/2`, `remove_tool/2`: helpers over `set_agent(:tools, ...)`
  (tools are not persisted).
- `:tree` events fire on every tree mutation (turn commits, navigation,
  branch/regen initiation).

Note: `set_agent/2,3` has already shipped with Phase 7.

**Dependencies:** Phase 7.

**Acceptance:**

- Branching flow: prompt A, get response; navigate back to A; prompt B
  (branches from A); tree structure and store contents verified.
- Regen flow: regen assistant node; original preserved; new assistant
  is sibling; cursor updated to new branch.
- Cursor navigation: navigate away and back preserves previous branch
  via cursors.
- `set_title` survives restart.
- Change-detection correctness: navigation (which calls
  `Agent.set_state(messages: _)`) does not spuriously persist state.

---

## Beyond phase 8

Candidates for follow-up work, detailed in `session-design.md` (Parked
section):

- **`Omni.Session.Manager`** — supervisor, registry, DynamicSupervisor,
  idle-timeout self-termination, `Manager.delete/1` convenience. Likely
  the next major design phase once Session proper is stable.
- **`:data` field on Agent state** — app-defined per-session metadata
  slot on Agent rather than Session. Deferred until a concrete consumer
  surfaces.
- **Title auto-generation helpers** — `auto_title:` start option as sugar
  over the subscribe-and-set pattern.
- **Retry / write-behind queue** for high-latency store adapters.
- **Persistent event log / replay** — subscribers resuming from a
  sequence number after process restart.
- **Agent init-triggers-initial-prompt** — extended `init/1` return or
  `:prompt` start option (parked in `agent-redesign.md`).

These are deferred until the phases above are in hand and concrete need
has been demonstrated.
