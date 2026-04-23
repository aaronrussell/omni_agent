# Test review follow-ups

Open items from the post-phase-9 test review. The top-priority batch
(Process.sleep cleanup, `:rest_for_one` supervision tests, DynSup
pinning test, four weak-assertion fixes, `branch/3` cancel/error +
`save_state` error-path tests) landed across commits `0127ab7`,
`fff0361`, `081626e`, `78aa0dd`, `d7894fa`. Everything catalogued
here is what remains.

Each item below is self-contained — file paths, the invariant being
tested, and a suggested approach. Pick any and run with it.

---

## Coverage gaps — safety-critical invariants

### `last_persisted_state` is not corrupted on `save_state` failure
**File:** new test in `test/omni/session/persistence_test.exs` `store errors` describe.
**Invariant:** `session.ex:913-928` — on `save_state` failure, `last_persisted_state` is *not* updated, so a subsequent identical save retries (doesn't short-circuit as "unchanged").
**Approach:** Failing store with `fail_save_state: :disk_full` + delegate. `set_title("a")` → observe `:store {:error, :state, :disk_full}`. Flip the Failing store's config to succeed (or swap to a pass-through delegate), call `set_title("a")` again with the *same* title and assert `save_state` fires again (via a `:store {:saved, :state}` event or by asserting the delegate was called). A regression that updated `last_persisted_state` on failure would skip the retry and this assertion would fail.

### `:persistent_term` config survives child restart
**File:** new test in `test/omni/session/manager_test.exs` `supervision strategy` describe.
**Invariant:** `manager.ex:179-182` — config is stored in `:persistent_term` so it survives a Registry restart under `:rest_for_one`. After a cascade, `config/1` must still resolve.
**Approach:** Create session, kill Registry (reusing the existing test's setup), wait for supervisor restart, then call `Manager.create/2` with a fresh id. If `:persistent_term` were lost, `config(manager)` would raise. The existing `:rest_for_one` tests exercise this implicitly (new `create` calls would crash if config were lost) but don't pin it explicitly.

### `save_tree` `:new_node_ids` keyword shape
**File:** new test in `test/omni/session/persistence_test.exs`.
**Invariant:** `session.ex:901-911` passes `[new_node_ids: [...]]` to the store; the FileSystem adapter relies on this to choose append vs. full-rewrite. A regression that dropped the keyword or passed the wrong shape would break any adapter other than a stub.
**Approach:** A spy/capture store adapter (could extend `Failing` or add a new `Capturing` store under `test/support/`) that records `save_tree`'s `opts` argument. Run one prompt, assert `opts[:new_node_ids]` is `[user_id, assistant_id]` (in push order).

### Multi-segment `:continue` inside a regen
**File:** new test in `test/omni/session/branch_test.exs`.
**Invariant:** `session-design.md` — the "drop duplicate leading user" rule applies *only* to the first segment of a regen; `regen_source` is cleared after the first commit. Subsequent continuation segments push normally from the head of the active path.
**Approach:** `ContinueAgent` (in `test/support/test_agents.ex`) + `branch/2` (regen) with fixtures that produce two segments. First segment: tree drops the duplicate leading user. Second segment's `:turn {:continue, _}`: assert children append normally under the new assistant, and `:sys.get_state(session).regen_source == nil` before the second segment commits.

### Tracker hand-off ordering (observable)
**File:** new test in `test/omni/session/manager_tracker_test.exs`.
**Invariant:** `manager-design.md:730` — `Manager.create/2` and `Manager.open/3` synchronously hand off to `Tracker.add/3` before returning. `list_running/1` called immediately after `create/2` must include the new entry; a subscriber that subscribes *before* `create/2` must see `:session_added`.
**Approach:** Two tests. (1) `Manager.create(...)` → immediately call `list_running(m)` and assert the new id is present (no `eventually`). (2) `subscribe` → `create` → `assert_receive :session_added` with a small timeout. The existing `list_running` tests use `eventually`, which masks a broken hand-off.

---

## Coverage gaps — behavioural

### Agent `evaluate_head` branches
- **"All tool uses rejected"** — when every `handle_tool_use/2` returns `:reject` or `:result` (none `:execute`), the executor never spawns. `server.ex:494-515` has this branch but no test covers it. Add a test agent that rejects both tool uses in `anthropic_multi_tool_use.sse`.
- **`max_steps: 0`** — `prompt(agent, content, max_steps: 0)` likely hits the "immediately max_steps_reached" edge. Current implementation calls `finalize_turn(nil, ...)` which may produce a response with `output: nil`. Likely a latent bug; add a test even if it documents the current behaviour.
- **`max_steps_reached? AND next_prompt != nil`** — `server.ex:638-649`'s `cond` prefers `complete_turn` in this branch. Covered indirectly; not pinned. Add a steering-style test with both conditions true simultaneously.

### Agent `Snapshot.partial` is a real `Message` mid-stream
**File:** `test/omni/agent/snapshot_test.exs:28-58`.
**Gap:** Assertion is "partial is `nil` or an assistant Message" — a regression that always returned `nil` would pass. Hard to make deterministic, but feasible with a chunked `Req.Test` response that yields between events. Use `stub_fn` with explicit `:timer.sleep` between written chunks (or a receive-gated chunk sender).

### Session `subscribe/2,3` return snapshot shape
**File:** `test/omni/agent/pubsub_test.exs` and `test/omni/session/pubsub_test.exs`.
**Gap:** Only `subscribe/1` has a snapshot-shape assertion. `subscribe/2,3` (arbitrary pid, subscribe modes) are called but the returned snapshot is discarded with `{:ok, _}`. Add one assertion per arity that the snapshot struct has the expected fields populated.

### Session `unsubscribe` of a never-subscribed pid
**File:** `test/omni/session/pubsub_test.exs` or `subscribe_modes_test.exs`.
**Gap:** No test — the no-op path is inferred from `find_monitor_ref returning nil`. Should return `:ok` cleanly without crashing or disturbing other subscribers.

### Session DOWN handler for unknown ref
**File:** `test/omni/session/pubsub_test.exs`.
**Gap:** `session.ex:768-771` has an early-return for DOWNs whose ref isn't in `monitors`. Not exercised. Send a synthetic `{:DOWN, make_ref(), :process, self(), :normal}` to the session via `send/2` and assert it doesn't crash.

### Session `:status :paused` forwarding
**File:** `test/omni/session/status_forwarding_test.exs`.
**Gap:** Only `:running`/`:idle` paths are tested. Use `PauseAgent` to force a pause and assert the session forwards the `:paused` status event.

### `Tree.new/1` hydrate-then-mutate with sparse IDs
**File:** `test/omni/session/tree_test.exs`.
**Invariant:** `Tree.push_node/3` derives next id from `map_size(nodes) + 1`. If `Tree.new/1` accepts non-contiguous ids (which it does), a subsequent `push` could collide.
**Approach:** Hydrate a tree with ids `[1, 2, 5]`, push, assert the new id is `> 5` (or at least non-colliding). If the current behaviour is "this is always contiguous by construction, so collision is OK", add a test that documents it + asserts.

### `Tree.new/1` with `nodes` as a map
**File:** `test/omni/session/tree_test.exs`.
**Gap:** Only the list form is tested; source explicitly handles `is_map(nodes)` too. One trivial round-trip test.

### FileSystem `encode_state` schema enforcement
**File:** `test/omni/session/store/file_system_test.exs`.
**Invariant:** Unknown keys are silently dropped; non-list `:opts` is silently dropped. Documented contract; no negative test.
**Approach:** Call `save_state(cfg, id, %{title: "t", garbage: "x"})` and assert the persisted `session.json` has no `"garbage"` key. Same for `:opts` being a non-list.

### FileSystem: partial-but-non-empty `session.json` degrades to `:not_found`
**File:** `test/omni/session/store/file_system_test.exs` `durability` describe.
**Gap:** Only the empty-file case is tested. A real torn write leaves `{"path":[1,2` or similar. `read_session_json` rescues all exceptions, so this should degrade the same way — but no test confirms it.

### FileSystem: `decode_model` tolerates unknown provider atom
**File:** `test/omni/session/store/file_system_test.exs`.
**Invariant:** `String.to_existing_atom` can raise. The load path is supposed to be tolerant. Currently untested.
**Approach:** Write a `session.json` by hand with `"model": ["unknown_provider", "x"]` and call `load/2`. Confirm it either returns a sensible error tuple or gracefully skips the model field — whichever the current behaviour is, pin it.

### Manager collision: Session-level `init/1` guard
**File:** `test/omni/session/manager_test.exs`.
**Gap:** Manager's pre-check catches most collisions. The Session-level guard (`{:error, :already_exists}` on `new: <binary>`) is the defence-in-depth layer. No test exercises it in isolation — add a test where the store is modified out-of-band between the Manager pre-check and Session's init.

### Manager `open/3` `:existing` branch drops all four start-time opts
**File:** `test/omni/session/manager_test.exs`.
**Gap:** Only `:title` is tested. The design lists `:agent`, `:title`, `:idle_shutdown_after`, `:subscribers` as dropped. Add a sweeping test that passes all four and asserts none take effect on the returned session.

### Manager cleanup paths fire exactly one `:session_removed`
**File:** `test/omni/session/manager_tracker_test.exs`.
**Gap:** Each cleanup path (close, delete, crash, idle-shutdown) is tested in isolation; no test asserts a race (e.g. close + crash simultaneously) doesn't double-emit.

---

## Weak assertions requiring new fixtures

These were deferred from Pattern C because they need new fixtures or a structural change.

### `persistence_test.exs` per-segment usage mirror
**File:** `test/omni/session/persistence_test.exs:63-90`.
**Issue:** Assertion is `Enum.uniq(usages) |> length() == 1`. Cannot distinguish "attached to last assistant of segment" from "attached to every assistant" — all three segments use identical text fixtures so usages are naturally identical.
**Approach:** Synthesise (or capture) a multi-assistant-segment fixture where `response.messages` is e.g. `[user, assistant, assistant, ...]`. Then assert only the *last* assistant in each segment carries usage; intermediate assistants have `usage == nil`. This may require a new fixture under `test/support/fixtures/synthetic/`.

### `continuation_test.exs` segment-usage distinction
**File:** `test/omni/agent/continuation_test.exs:78-98`.
**Issue:** Same `Enum.uniq |> length == 1` weakness. Same fix — reuse the multi-assistant-segment fixture built for the persistence test.

### `continuation_test.exs` per-prompt opts are ephemeral
**File:** `test/omni/agent/continuation_test.exs:120-137`.
**Issue:** Test would pass whether `max_steps: 1` persisted or not — both cases complete with `:stop` and go idle. No observable difference.
**Approach:** First prompt uses `max_steps: 1` against a tool-loop fixture that would normally require 3+ steps. Confirm the first prompt stops at step 1. Second prompt (no opts) against the same tool-loop fixture — if opts persisted, second prompt would also cap at 1 step. The regression is visible only with a fixture that forces multi-step behaviour.

### `manager_test.exs` delete ordering
**File:** `test/omni/session/manager_test.exs` `delete/2` describe.
**Issue:** Test asserts session is stopped and store entry is gone; doesn't assert ordering. If `delete` were re-implemented as delete-then-stop, test would still pass.
**Approach:** Subscribe to Manager events, call `delete/2`, assert `:session_removed` arrives *before* `Store.exists?` returns `false` — or capture the order via monitoring the session pid's DOWN vs the Failing store's `delete` callback.

---

## Overspecification — replace `:sys.get_state` with observable assertions

### Manager/Tracker internal state inspection
**Files:**
- `test/omni/session/manager_test.exs` — `controllers` MapSet checks in the `create/2` subscribe tests.
- `test/omni/session/manager_tracker_test.exs` — `subscribers` MapSet checks (at least two tests reach into `:sys.get_state(tracker).subscribers`).

**Issue:** Tests lock in the internal data structure. An ETS-based or schema-change refactor would break the tests without breaking the contract.
**Approach:** Replace with event-based assertions — e.g. for subscriber idempotency, subscribe twice and assert exactly one `:session_added` arrives when a session is created; for cleanup on subscriber death, spawn a subscriber that dies, then create a session and assert the dead pid does *not* receive the event.

### Agent error tests assume `step_task` is set
**File:** `test/omni/agent/error_test.exs:65-165` (three tests).
**Status:** Partially addressed in commit `0127ab7` (added `:running` sync before `:sys.get_state`). Still uses `:sys.get_state` to grab `step_task` / `executor_task`. Left as-is intentionally; flag for future cleanup if a behavioural alternative emerges.

### `idle_shutdown_test.exs` shutdown_timer field reads
**File:** `test/omni/session/idle_shutdown_test.exs`.
**Status:** Partially addressed — the `Process.sleep` issue is fixed via `eventually`. The field is still read directly. Same caveat as above: no observable alternative currently exists for "timer is armed".

---

## Test isolation

### Hoist inline `defmodule`s in lifecycle tests
**File:** `test/omni/agent/lifecycle_test.exs:18-78` (several `defmodule CaptureState`, `BadInit`, etc. inside test bodies).
**Issue:** Inline `defmodule` under `async: true` creates global atoms and can race on redefine warnings. Hoist into `test/support/test_agents.ex`.

### Replace `spawn_link` helpers with `spawn`
**Files:**
- `test/omni/agent/pubsub_test.exs:38-58, 82-101, 138-150` — `spawn_link` helpers kill the test on crash.
- `test/omni/session/subscribe_modes_test.exs:163-201` — `spawn(fn -> Process.sleep(:infinity) end)` without cleanup; tag with `on_exit` or link to the test's `start_supervised` lifecycle.

### `pause_resume_test.exs` misleading cleanup
**File:** `test/omni/agent/pause_resume_test.exs:5-24`.
**Issue:** "Clean up" comment is misleading — the stub re-registration uses a new stub name that the agent isn't wired to. The agent remains paused. Either wire a real teardown (cancel the agent) or delete the dead code.

---

## Misplaced / duplicate tests

### `manager_test.exs:347-358` `:limit`/`:offset` test
**Issue:** Pure pass-through to Store; belongs in `test/omni/session/store_test.exs` or `file_system_test.exs`.

### `prompt_test.exs:55-83` two unrelated assertions
**File:** `test/omni/agent/prompt_test.exs`.
**Issue:** Test starts a second agent (`agent2`) for the back half. Split into two tests.

### Duplicated `wait_until` / `eventually`
**Files:**
- `test/omni/session/manager_tracker_test.exs:34-52` — local `wait_until/1`.
- `test/support/session_case.ex:60-77` — shared `eventually/1`.
**Approach:** Delete `wait_until`; use `eventually`. Also consider promoting `eventually` from `SessionCase` to a shared `Omni.TestHelpers` module so `agent_case.ex`-based tests can use it (currently the `lifecycle_test.exs` inline poll loop reinvents it).

### `events_test.exs` drain-chatter sleeps already removed
**Status:** Addressed in commit `0127ab7`. No action.

---

## Low-priority / nits

- `test/omni/agent/steering_test.exs` — 6 remaining `stub_slow + Process.sleep(50)` patterns (in the `prompt while running` pair and the `cancel` describe block) not covered by the main sleep cleanup. Migrate to receive-gated stubs for consistency.
- `test/omni/agent/ordering_test.exs:89` — `Process.sleep(250)` for tool-ordering differential; bumped from 100 ms but still sleep-based. Replace with a receive/send handshake between the two tool handlers when a cleaner pattern surfaces.
- `test/omni/session/store/file_system_test.exs` — five `Process.sleep(50)` for `updated_at` ordering. Interim; real fix is clock injection.
- `test/support/failing_store.ex` — module is `Omni.Session.Store.Failing` but file is `failing_store.ex`. Minor naming nit.
- `test/omni/session/store_test.exs` — dispatch tests assert `:ok` / `false` against a hardcoded `EchoAdapter`. The leading match is decorative; the real assertion is `assert_received`. Drop the leading match for clarity.
- `test/omni/session/store_test.exs:119-123` — `Store.exists?/2` only tests the `false` branch. Add the `true` branch for symmetry.
- `test/omni/agent/events_test.exs:7-40, 60-89` — event-shape filters silently drop `:status`/`:retry` etc. Acceptable for readability but worth a comment noting the filter's purpose.

---

## Reference

Original test review synthesis is in the conversation transcript for commit range `0127ab7..d7894fa`. The per-suite sub-agent reports (Agent, Session core, Tree+Store, Manager) are the most detailed source if any item here needs expansion.
