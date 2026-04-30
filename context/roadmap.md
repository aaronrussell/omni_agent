# Roadmap

Forward-looking notes for `omni_agent`. The completed build-out of
Agent, Session, Store, and Manager is documented in
`context/design.md` — this file tracks what might come next.

---

## Scheduled

- **Work through `context/test-review-followups.md`.** A catalogued
  list of remaining test items from the post-phase-9 review —
  coverage gaps for safety-critical invariants, behavioural gaps,
  weak assertions needing new fixtures, over-specified tests to
  replace with observable assertions, and a few nits. Each entry is
  self-contained (file, invariant, suggested approach) and can be
  picked up independently. No ordering required; work through
  incrementally.

---

## Parked ideas

Open questions worth exploring before committing to a shape. Not
scheduled.

- **Callback-driven title generation.** Rather than an `auto_title:`
  sugar helper, explore a pattern where the Agent produces the title
  from inside a callback and the Session picks it up for persistence.
  The blocker is that callbacks currently have no clean way to emit
  structured values back up the stack — solving that might want a
  generic callback-side event-emission API, which is itself a broader
  design question worth its own exploration.

- **`init/1` returning an initial prompt.** An extended `init/1` return
  (or `:prompt` start option) that puts the agent straight into
  `:busy` with a staged prompt, producing a response before the
  caller interacts. Needs concrete use cases before a shape is worth
  committing to.

- **Session-level `:data` field.** App-defined per-conversation
  metadata, persisted alongside `title` and surfaced in `Store.list`.
  Use cases: tagging sessions for filtered listings (project_id,
  priority, category); attaching app-owned identity (user_id,
  tenant_id) without baking it into the system prompt. Distinct from
  `state.private` on Agent — process-lifetime callback state stays
  there. Open questions on the API shape (whole-map replace vs.
  Map.put style; Session events on change; how callbacks read it —
  via `private[:omni]` projection?).
