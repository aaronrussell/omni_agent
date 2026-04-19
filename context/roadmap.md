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

---

## Phase 6 — Session: Store behaviour + reference adapter

**Status:** Not started.

**Spec:** `session-design.md` (Storage).

**Goal:** Define the storage adapter contract and ship a reference
filesystem adapter.

**Key work:**

- `Omni.Session.Store` dispatch module.
- `Omni.Session.Store.Adapter` behaviour (`save_tree`, `save_state`,
  `load`, `list`, `delete`).
- `%Omni.Session.Store{adapter, config}` struct threaded from Session
  start options.
- `Omni.Session.Store.FileSystem` reference adapter: per-session
  directory, `nodes.jsonl` append-only log, `state.json` overwrite blob,
  `Omni.Codec` for term ⇄ JSON.
- Integration tests: create, save_tree (append with `:new_node_ids`),
  save_state (overwrite), load (round trip), list, delete, error
  scenarios.

**Dependencies:** Phase 5.

**Acceptance:**

- Filesystem adapter round-trips a tree with branches and metadata
  losslessly.
- Adapter behaviour documented clearly enough that SQLite / Postgres /
  other adapters could be implemented from the spec alone.

---

## Phase 7 — Session: core GenServer

**Status:** Not started.

**Spec:** `session-design.md` (State shape, Lifecycle, Events, Snapshot,
Pub/sub, Load-mode resolution).

**Goal:** The Session GenServer itself: lifecycle, Agent wrapping,
turn-driven persistence, pub/sub, basic API surface.

**Key work:**

- `Omni.Session` GenServer.
- `start_link/1` supporting `:new` (explicit or auto-generated id),
  `:load` (hydration from store), namespaced `:agent` / `:store` options,
  and load-mode resolution rules.
- Auto-generated IDs via `:crypto.strong_rand_bytes(16)
  |> Base.url_encode64(padding: false)`.
- Linked Agent startup; event forwarding with `{:agent, _, _, _}` →
  `{:session, _, _, _}` re-tagging.
- Turn commit → `Store.save_tree` with `:new_node_ids`.
- Agent `:state` event → change-detection via `last_persisted_state` →
  `Store.save_state`.
- `last_persisted_state` seeded on hydration before Agent start, to
  avoid spurious post-init writes.
- `:store {:saved, _}` / `:store {:error, _}` events; session never
  halts on store errors.
- Subscribe/unsubscribe with monitors; atomic snapshot-on-subscribe via
  `%Omni.Session.Snapshot{id, title, tree, agent}`.
- Turn control passthrough: `prompt/2,3`, `cancel/1`, `resume/2`.
- Inspection: `get_agent/1,2`, `get_tree/1`, `get_title/1`,
  `get_snapshot/1`.
- `stop/1` graceful shutdown.
- Agent crash = Session crash (linked, no `trap_exit`).

**Dependencies:** Phases 5 and 6.

**Acceptance:**

- New-session lifecycle: create, prompt, verify tree persisted. Restart
  process, `load:` same id, full conversation restored.
- Multi-turn persistence works; cancel/error turns do not corrupt
  persisted state.
- Concurrent subscribers receive identical event streams.
- Store errors do not halt the session; `:store {:error, _}` events
  fire.
- Load-mode resolution edge cases covered: unresolvable persisted model
  falls back to start opt; `agent: [messages: _]` rejected on `:new`,
  ignored on `:load`.

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
- `set_agent/2,3` delegating to `Agent.set_state`.
- `set_title/2`: updates title, triggers `save_state` via digest path,
  emits `:title` event.
- `add_tool/2`, `remove_tool/2`: helpers over `set_agent(:tools, ...)`
  (tools are not persisted).
- `:tree` events fire on every tree mutation (turn commits, navigation,
  branch/regen initiation).

**Dependencies:** Phase 7.

**Acceptance:**

- Branching flow: prompt A, get response; navigate back to A; prompt B
  (branches from A); tree structure and store contents verified.
- Regen flow: regen assistant node; original preserved; new assistant
  is sibling; cursor updated to new branch.
- Cursor navigation: navigate away and back preserves previous branch
  via cursors.
- `set_title` survives restart.
- `set_agent(:tools, _)` does not trigger spurious `save_state` (tools
  not in persistable subset).
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
