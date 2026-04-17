# Roadmap

A sequence of phases for the current direction of work. Each phase leaves
the system in a working, tested state and can land as its own commit or PR.

Detailed design specs live alongside this file (e.g. `agent-redesign.md`
for the Agent refactor). This roadmap is an index, not a spec.

---

## Phase 1 — Agent: state shape and `init/1`

**Status:** Done.

**Spec:** `context/agent-redesign.md` (State shape, Validation, Callbacks).

**Goal:** Replace the nested `%Context{}` inside `%State{}` with a flat
state, simplify the stash story, and move `init/1` to a state-in/state-out
shape.

**Key changes:**

- Flatten `%State{}` to `{model, system, messages, tools, opts, private,
  status, step}`. Drop `:meta`.
- `:private` settable via `start_link` option, in addition to `init/1`.
- `init/1` receives a fully-resolved `%State{}` and returns
  `{:ok, state} | {:error, term}`.
- Add `set_state(:messages, ...)` validation — list must be empty or end
  with an `:assistant` message containing no `ToolUse` blocks.
- Validate the state returned from `init/1` against the same rule.
- Propagate the shape change through all internal references
  (`state.context.x` → `state.x`), test helpers, and test fixtures.

**Dependencies:** None. Foundation for all subsequent phases.

**Acceptance:**

- All existing tests pass (with signature/shape updates).
- No `state.context` references remain.
- `set_state(:messages, ...)` rejects invalid input with
  `{:error, :invalid_messages}`.

---

## Phase 2 — Agent: event model

**Status:** Done.

**Spec:** `context/agent-redesign.md` (Events, Turn lifecycle).

**Goal:** Redesign the event catalogue to support per-message granularity,
commit-on-every-turn-segment semantics, and externally-visible state
mutations.

**Key changes:**

- Add `:message` event fired per message appended to pending.
- Collapse the current `:stop` and `:continue` events into `:turn` with
  `{:stop, response}` / `{:continue, response}` tuple variants. Both
  commit pending to `state.messages`.
- Add `:state` event fired after a successful `set_state`.
- Align `:step.response.messages` and `:turn.response.messages` with
  segment semantics (per-step / per-segment, not per-turn).
- Update event-ordering tests and add new tests for `:message`, `:state`,
  and the `:turn` variants.

**Dependencies:** Phase 1 (benefits from flat state when expressing commit
logic).

**Acceptance:**

- Single chatbot turn produces: `:message (user) → streaming → :message
  (assistant) → :step → :turn {:stop, ...}`.
- Mega-turns produce a `:turn {:continue, ...}` per segment and a final
  `:turn {:stop, ...}`.
- Cancel/error do not emit `:turn` and leave `state.messages` unchanged.
- `set_state` emits `:state` with the new full `%State{}`.

---

## Phase 3 — Agent: pub/sub and snapshot

**Status:** Not started.

**Spec:** `context/agent-redesign.md` (Pub/sub, Snapshot).

**Goal:** Replace the single-listener model with native multi-subscriber
pub/sub, add atomic snapshot-on-subscribe, and retire the `listener`
concept.

**Key changes:**

- Replace `listener` with a `MapSet` of subscribers (plus monitors for
  cleanup on subscriber death).
- Add `subscribe/1,2`, `unsubscribe/1,2`.
- Add `%Omni.Agent.Snapshot{state, pending, partial}` struct and
  `get_snapshot/1`.
- Track `partial_message` internally — updated from streaming deltas,
  cleared on `:message` emission for the assistant.
- Add `:subscribe` and `:subscribers` start options. Remove `:listener`
  start option and `listen/2`.
- Guarantee atomic subscribe (snapshot built + subscriber added in a single
  `handle_call` clause).
- Tests: multi-subscriber delivery, late-join consistency, subscriber
  cleanup on death, snapshot correctness mid-stream.

**Dependencies:** Phase 2 (snapshot tracks `partial_message`, which is
cleanly bounded by the `:message` event introduced in phase 2).

**Acceptance:**

- Multiple subscribers receive identical event streams.
- A subscriber joining mid-stream receives a snapshot whose combined
  `messages ++ pending ++ List.wrap(partial)` equals the live view, and
  every subsequent event fits on top.
- Dying subscribers are removed without error.
- No `listener`-related code remains.

---

## Phase 4 — Session: design

**Status:** Not started. **Design work required before any implementation.**

**Spec:** To be written (`context/session-design.md` or similar).

**Goal:** Design the wrapper process that owns conversation lifetime —
identity, persistent storage, a branching message tree, Session-level
pub/sub, and navigation/regeneration semantics.

**Open design questions to settle before implementation:**

- Storage adapter shape. Behaviour vs callback module vs `Req.Plug`-style
  function. How adapters signal partial-write failures.
- Tree schema. Node identity, parent/child references, how tool-use /
  tool-result pairs are grouped in the tree.
- Active path materialization. When (and how often) the path is
  recomputed. Whether it lives in Session state or is derived on demand.
- Session-level event catalogue. `:node`, `:tree`, and how Agent events
  are forwarded/augmented.
- Session lifecycle. Whether the inner Agent is long-lived or spun up per
  turn. How Session behaves when idle (Agent alive? Dead? Hydration cost?).
- Late-join consistency across Agent lifetimes. How Session composes its
  own snapshot from tree + active-path messages + (when live) an Agent's
  partial.
- Public API shape. `Session.prompt`, `navigate`, `branch`, `regenerate`,
  `subscribe`, `tree`, etc. Which Agent operations are surfaced vs hidden.
- Naming — confirm `Omni.Session` or alternative (`Conversation`,
  `Thread`, etc.).

**Dependencies:** Phases 1–3 complete, so Session can be built against a
stable Agent API with no further churn.

**Acceptance (for the design phase itself):**

- A `session-design.md` document exists and captures decisions on each of
  the open questions above.
- A follow-up implementation roadmap (phases 5+) is appended here or in
  that document.

---

## Beyond phase 4

Not scheduled, but known candidates for future work:

- Init-triggers-initial-prompt support (extended `init/1` return shape or
  `:prompt` start option). Parked in `agent-redesign.md`.
- Replay / resume-from-sequence semantics for Session subscribers (a
  persistent event log).
- Supervision primitives for running multiple Sessions under a named
  registry.

These are deferred until the phases above are in hand and the concrete
need has been demonstrated.
