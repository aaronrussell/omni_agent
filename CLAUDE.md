# CLAUDE.md

Guidance for Claude Code working in `omni_agent`. Architecture details
live in `context/design.md` — this file covers what to know as a
developer on this codebase and the conventions to follow.

## What this package is

`omni_agent` is an Elixir package of OTP building blocks for stateful,
long-running LLM interactions. It layers on top of
[`omni`](https://github.com/aaronrussell/omni), the stateless LLM API
library:

```
Omni.Session.Manager   — supervises many sessions (optional)
      │
Omni.Session           — conversation lifetime: tree, persistence,
                         navigation
      │
Omni.Agent             — turn engine: model, context, tools, events
      │
Omni (stateless)       — stream_text / Tool.Runner / structs
```

Each layer depends only on the one below and uses only the lower
layer's public API. Each layer can be used standalone.

- **Agent** owns the **turn** — ephemeral, no identity, no persistence.
- **Session** owns the **conversation** — id, branching tree, store
  adapter, linked Agent.
- **Manager** owns **multi-session lifecycle** — Registry,
  DynamicSupervisor, Tracker, and cross-session pub/sub.

For the full design reference (state shapes, events, callbacks,
persistence triggers, navigation mechanics, supervision strategy), read
`context/design.md`.

## Build & test commands

```bash
mix compile                    # Compile
mix test                       # Run all tests
mix test path/to/test.exs      # Single file
mix test path/to/test.exs:42   # Single test by line
mix format                     # Format
mix format --check-formatted   # CI formatting check
```

## Dependencies

- **`omni`** — the stateless LLM API package. Local path dep during
  development, hex dep for release.
- **`plug`** (test only) — for `Req.Test` plug-based stubbing.

All other transitive deps (Req, Peri, Jason, etc.) come through `omni`.

## Module layout

```
lib/omni/
├── agent.ex                       # public: behaviour, use macro, API
├── agent/{state,snapshot}.ex      # public structs
├── agent/{server,step,executor}.ex # internal (@moduledoc false)
├── session.ex                     # public: Session GenServer + API
├── session/{snapshot,tree}.ex     # public
├── session/store.ex               # adapter behaviour + dispatch
├── session/store/file_system.ex   # reference adapter
├── session/manager.ex             # Supervisor + use macro + API
└── session/manager/tracker.ex     # internal (@moduledoc false)
```

## Conventions

### Terminology

- **Tool use**, not "tool call" (aligns with Anthropic and `omni`).
- **Turn** = one prompt-to-stop cycle. **Segment** = one natural stop
  within a turn (at `:turn {:continue, _}` or `:turn {:stop, _}`).
  **Step** = one LLM request-response.
- Agent statuses: `:idle`, `:running`, `:paused`. Status determines
  which API calls are valid. Navigation and branching on Session are
  **idle-only**; `prompt/3` is not.

### State invariants

- `state.messages` on an idle Agent is empty **or** ends with an
  `:assistant` message containing no `%ToolUse{}` blocks. This is
  enforced at `set_state(:messages, _)` and on the state returned from
  `init/1`.
- `state.private` is not settable via `set_state` — callbacks mutate
  it via `%{state | private: _}`.
- Settable fields on Agent: `:model | :system | :messages | :tools |
  :opts`. All values **replace** — no merge semantics at the API
  boundary (use the function form of `set_state/3` to transform).
- Session's `set_agent/2,3` delegates straight to `Agent.set_state`.

### Events

- Event format: `{:agent, pid, type, payload}` (Agent),
  `{:session, pid, type, payload}` (Session — re-tags Agent events
  verbatim), or `{:manager, module, type, payload}` (Manager —
  **module atom**, not Tracker pid).
- `:step.response.messages` is always `[user, assistant]` — exactly
  two messages. The user is whatever prompted the step (initial
  prompt, continuation, or tool-result user).
- `:turn.response.messages` is segment-scoped — only the messages
  committed in that segment, and `response.usage` is segment-scoped
  too (turn_usage resets per segment to avoid double-counting in the
  persisted tree).
- `:status` precedes every event derived from a status transition
  (e.g. `:status :idle` before `:turn {:stop, _}`). Idempotent
  transitions don't emit.
- `:state` fires only on `set_state/2,3` mutations, **not** on
  turn-boundary commits. Consumers distinguishing mutation from
  progress rely on this separation — Session's persistence path is
  one of them.

### Persistence triggers

Two categories with different trigger rules:

- **Tree** (`save_tree`) is Session-driven — every turn commit,
  navigation, or branch initiation calls it.
- **State map** (`save_state` — `model`, `system`, `opts`, `title`)
  is change-detected. Session diffs the persistable subset against
  `last_persisted_state` on every Agent `:state` event and every
  `set_title/2` call; unchanged → no write. `opts` is canonicalised
  (sorted keyword) to avoid spurious saves on reordered-but-equivalent
  inputs.

Store calls are synchronous and always go through Session's mailbox
— no concurrent-write race for a given session. Store errors never
halt Session; they only emit `:store {:error, _, _}`.

### Public vs internal

- Public modules have `@moduledoc` + `@typedoc` / `@doc` / `@spec` on
  all public surfaces.
- Internal modules (`Agent.Server`, `Agent.Step`, `Agent.Executor`,
  `Manager.Tracker`) are `@moduledoc false`.
- Doc tone: practical over theoretical, concise, example-driven for
  key APIs. Lead with what you do, not what things are. Rely on
  `@spec` for types — don't repeat type info in prose.
- Private functions don't need `@doc`.

## Development do's and don'ts

### Do

- **Use the public API from each layer.** Session uses only Agent's
  public API; Manager uses only Session's. No downward reaching.
- **Prefer editing existing files.** The module layout is settled.
- **Run the affected test file (or the whole suite) before claiming
  done.** Tests run with no network — no reason to skip.
- **Keep changes scoped to the layer.** If a refactor seems to need a
  change to Agent for something Manager wants, ask first — we worked
  hard to keep layering one-directional.
- **Match existing error shapes.** `{:error, :not_idle}`, `{:error,
  :invalid_messages}`, `{:error, :already_exists}`, `{:error,
  {:invalid_opt, key}}`, etc. — don't invent new shapes without a
  reason.

### Don't

- **Don't add features beyond what the task requires.** No speculative
  abstractions, hypothetical future-proofing, or "while I'm in here"
  refactors. Three similar lines beats a premature helper.
- **Don't fall back silently when a field is load-ambiguous.** The
  load-mode resolution rules in `context/design.md § 5.4` are
  deliberate — follow them, don't add new fallbacks.
- **Don't persist tools or private state.** Tools hold function
  refs; `private` is callback-module runtime state. Both are
  explicitly out of the persistable subset.
- **Don't write `@doc` for edge cases that aren't public API.** The
  tree's auto-ID scheme, the regen `drop-leading-user` dance, and
  similar mechanics live in code comments and in `context/design.md`
  — not in `@doc`.
- **Don't emit `:state` for turn commits or `:status` for idempotent
  transitions.** Session and Tracker rely on these contracts.
- **Don't bypass the DynamicSupervisor under Manager.** Sessions live
  under it by design so they outlive their callers.

## Testing

Tests live under `test/omni/agent/**` and `test/omni/session/**`. They
exercise the full lifecycle through the public API — no test reaches
into internal state.

- **Fixtures** in `test/support/fixtures/sse/` are real Anthropic API
  recordings from the `omni` package. Three files:
  `anthropic_text.sse`, `anthropic_tool_use.sse`,
  `anthropic_thinking.sse`.
- **Helpers** in `test/support/`:
  - `agent_case.ex` — `stub_fixture` (single response), `stub_sequence`
    (ordered multi-step), `stub_error`, event collection.
  - `session_case.ex` — same shape, adapted for sessions.
  - `test_agents.ex` — canned callback modules covering every callback
    path (init, handle_turn, handle_tool_use, handle_tool_result,
    handle_error, terminate).
  - `failing_store.ex` — store adapter that errors on demand.
- **Test env** — `test/support/` is compiled via `elixirc_paths(:test)`.
  No API keys required.

When adding tests:

- Prefer to exercise behaviour through `prompt` / `subscribe` /
  `resume` and assert on emitted events. Don't reach into the server
  struct.
- Avoid sleeps for synchronisation — use `assert_receive` on the
  event you are actually waiting for.
- If a behaviour isn't observable through events, adding a new event
  is usually the wrong fix. Check via `get_state` / `get_snapshot`, or
  revisit whether the behaviour is correct.

## Documentation

- All public modules must have a `@moduledoc`. Internal/private modules use `@moduledoc false`.
- All public types must have a `@typedoc`. Keep it on one line unless complex.
- All public functions must have a `@doc`. Rely on `@spec` for types — don't repeat in prose.
- Document options when a function accepts them.
- Private functions (`defp`) do not need `@doc` annotations.
- Tone: practical, concise, example-driven. Lead with what you do, not what things are.

## Where to look

- **Design** — `context/design.md` (the one reference doc).
- **Roadmap** — `context/roadmap.md` (parked ideas requiring exploration; no scheduled work).
- **Test review follow-ups** — `context/test-review-followups.md`
  (items worth revisiting in tests, not blockers).
- **Feedback / help** — `/help` or
  https://github.com/anthropics/claude-code/issues.
