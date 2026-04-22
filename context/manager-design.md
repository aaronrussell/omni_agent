# Manager Design

## Purpose

This document specifies the design of `Omni.Session.Manager`, a Supervisor
that bundles a Registry, a DynamicSupervisor, and a Tracker process to
provide multi-session lifetime management, id-based addressing, idle
shutdown, and a live cross-session status feed.

It builds on `session-design.md` and introduces small, well-scoped
additions to both `Omni.Agent` (a new `:status` event) and `Omni.Session`
(unified subscription modes, idle-shutdown mechanics) to support the
Manager's model. It is the spec for phase 9 of the roadmap.

## Scope

Covered:

- The `use Omni.Session.Manager` pattern for defining app-specific Manager
  instances.
- Manager's supervision shape, configuration, and public API.
- Agent and Session changes required to support idle shutdown and the
  cross-session status feed.
- The Tracker process and Manager-level pub/sub.
- A phased implementation plan.

Not covered:

- Cross-node or clustered Manager semantics. All designs here assume a
  single-node BEAM.
- Persistent event log / replay for Manager-level subscribers across
  restarts — parked in `session-design.md`.
- Per-user scoping / filtering at the Manager or Store API layer. Apps
  with multi-user needs maintain their own `user_id → session_id` index;
  the Manager/Store stay scope-agnostic. Multi-tenant apps with stronger
  isolation use one Manager per tenant (see Multi-instance below).

## Relationship to Agent and Session

Three layers, three temporal scopes:

- **`Omni.Agent`** — ephemeral, single-turn-focused. No identity, no
  persistence, no lifetime beyond its caller.
- **`Omni.Session`** — wraps a linked Agent, owns conversation identity,
  persistence, tree, and now an optional idle-shutdown policy. Session
  is still usable standalone (without a Manager).
- **`Omni.Session.Manager`** — supervises many Sessions, provides
  id→pid lookup, aggregate lifecycle, and cross-session status view.
  Optional convenience; Session works without it.

Each layer depends only on the one below:

```
Manager → Session → Agent
```

The Manager uses only Session's public API. Session uses only Agent's
public API. No downward reaching; no upward knowledge.

## Goals

- Keep the Manager's public surface small. Lifecycle (create, open, close,
  delete), discovery (whereis, list), and cross-session observation
  (subscribe, list_running). Nothing else.
- Make the `use` pattern the sole entry point, following the Ecto.Repo
  convention. Apps define their own Manager module; the Manager library
  generates thin delegation functions and a child spec.
- Keep Session self-sufficient. Additions required for Manager (unified
  subscribe, `:status` event forwarding, idle-shutdown) must be usable
  by bare-Session consumers too.
- Keep the Tracker honest: it observes sessions, it never controls them.
  Its state is derived and rebuildable on restart.

---

## Manager responsibilities

In scope:

- Supervise a Registry (id → pid), a DynamicSupervisor (per-session
  lifetimes), and a Tracker (cross-session status aggregation).
- Provide id-keyed session lifecycle: `create`, `open`, `close`, `delete`.
- Provide discovery: `whereis`, `list` (store-backed), `list_running`
  (Tracker-backed).
- Subscribe the caller as a controller at `create`/`open` time (default)
  so the session stays alive for the caller's scope.
- Hold an app-level default store and `idle_shutdown_after` that flow
  into every session it starts.
- Expose a Manager-level pub/sub for live cross-session status updates.

Out of scope (stays in Session or app layer):

- Turn control (`prompt`, `cancel`, `resume`) — stays on Session; callers
  address the pid directly once they have it.
- Navigation, branching, mutation — stays on Session.
- Per-user / per-tenant scoping — app layer or multi-instance Managers.

---

## The `use` pattern

`Omni.Session.Manager` is invoked via `use` in an app-defined module:

```elixir
defmodule MyApp.Sessions do
  use Omni.Session.Manager
end
```

This matches the Ecto.Repo / Phoenix.Endpoint pattern. The app's module
is a stateful, configured identity that:

- Serves as the first-arg "which manager" reference for the underlying
  implementation.
- Provides a natural home for app-specific helpers
  (`list_for_user/1`, an explicit `store/0`, etc.).
- Gives the Manager's supervisor and children deterministic, inspectable
  names (`MyApp.Sessions.Registry`, `MyApp.Sessions.DynamicSupervisor`,
  `MyApp.Sessions.Tracker`).

Apps that want multiple Managers (multi-tenant stores, per-workspace
isolation) define multiple modules:

```elixir
defmodule MyApp.Sessions.TenantA, do: use Omni.Session.Manager
defmodule MyApp.Sessions.TenantB, do: use Omni.Session.Manager
```

There is no single "default" Manager. Apps always define at least one
module. The two lines of boilerplate are the entry cost.

### What `use` generates

```elixir
defmodule MyApp.Sessions do
  use Omni.Session.Manager
end

# expands to roughly:
defmodule MyApp.Sessions do
  def child_spec(opts),
    do: Omni.Session.Manager.child_spec([{:name, __MODULE__} | opts])

  def start_link(opts),
    do: Omni.Session.Manager.start_link([{:name, __MODULE__} | opts])

  def create(opts \\ []),     do: Omni.Session.Manager.create(__MODULE__, opts)
  def open(id, opts \\ []),   do: Omni.Session.Manager.open(__MODULE__, id, opts)
  def close(id),              do: Omni.Session.Manager.close(__MODULE__, id)
  def delete(id),             do: Omni.Session.Manager.delete(__MODULE__, id)
  def whereis(id),            do: Omni.Session.Manager.whereis(__MODULE__, id)
  def list(opts \\ []),       do: Omni.Session.Manager.list(__MODULE__, opts)
  def list_running(),         do: Omni.Session.Manager.list_running(__MODULE__)
  def subscribe(opts \\ []),  do: Omni.Session.Manager.subscribe(__MODULE__, opts)
  def unsubscribe(),          do: Omni.Session.Manager.unsubscribe(__MODULE__)
end
```

Call sites read cleanly:

```elixir
{:ok, pid} = MyApp.Sessions.create(title: "New chat")
{:ok, pid} = MyApp.Sessions.open("abc-123")
:ok        = MyApp.Sessions.close("abc-123")
sessions   = MyApp.Sessions.list(limit: 50)
```

The underlying `Omni.Session.Manager.*` functions are part of the public
API (tests and advanced apps may call them with an explicit module
reference), but the `use`-generated module is the ergonomic default.

---

## Configuration

Config flows through `start_link` like any OTP child. No compile-time
config, no `otp_app:` indirection — apps read their own Application env
if they want deployment flexibility.

```elixir
# application.ex
children = [
  {MyApp.Sessions,
     store: Application.fetch_env!(:my_app, :session_store)}
]
```

### Options

| Option | Required | Meaning |
|---|---|---|
| `:store` | yes | `{module, keyword()}` — the store adapter and its config. Used by every session this Manager starts and by `list/1` / `delete/1`. |
| `:idle_shutdown_after` | no | `non_neg_integer() \| :infinity`. Default for sessions this Manager starts; overridden per-call via `idle_shutdown_after:` on `create`/`open`. Defaults to `300_000` (5 minutes) when absent. Set `:infinity` to disable Manager-wide. |
| `:name` | no | Overrides the registered name (default: the `use`-ing module). Rarely needed. |

Manager's config is deliberately minimal. There is no `agent_defaults`
or other "default start opts" mechanism — apps put that in their own
module. The `use`-ing module is the natural place for per-app helpers:

```elixir
defmodule MyApp.Sessions do
  use Omni.Session.Manager

  def start_chat(opts \\ []) do
    agent = Keyword.merge(
      [model: {:anthropic, "claude-sonnet-4-5"}, system: "You are helpful."],
      Keyword.get(opts, :agent, [])
    )
    create(Keyword.put(opts, :agent, agent))
  end
end
```

This pattern covers what `agent_defaults` would have, plus app-level
concerns like reading Application env, callback-module selection,
per-user customisation, etc.

### The `idle_shutdown_after` default

Manager-managed sessions default to `300_000` ms (5 minutes) of idle
before self-shutdown. The rationale: the Manager exists specifically
for running many sessions, memory management is a concrete concern,
and 5 minutes is long enough to survive brief tab reloads / network
blips while still bounding memory on abandoned sessions.

Apps that want a different app-wide policy set it at Manager start:

```elixir
{MyApp.Sessions, store: ..., idle_shutdown_after: 600_000}   # 10 min
{MyApp.Sessions, store: ..., idle_shutdown_after: :infinity} # never
```

Individual sessions override at create/open time:

```elixir
MyApp.Sessions.create(idle_shutdown_after: :infinity)         # exempt this session
MyApp.Sessions.create(idle_shutdown_after: 60_000)            # aggressive
```

Standalone Session (without a Manager) has **no default** — if
`idle_shutdown_after` is not set on `Session.start_link`, the session
runs until explicit stop. Opt into the feature by passing a value.

---

## Manager as Supervisor

The Manager is a Supervisor with three named children, using
`:one_for_one` restart strategy:

```
MyApp.Sessions (Supervisor, :one_for_one)
├── MyApp.Sessions.Registry (Registry, keys: :unique)
├── MyApp.Sessions.DynamicSupervisor (DynamicSupervisor, :temporary children)
└── MyApp.Sessions.Tracker (GenServer)
```

### Why each child

- **Registry** — provides id → pid lookup. Session processes register
  themselves by id using `{:via, Registry, {reg, id}}` as their
  GenServer name. Registered monitors auto-unregister on pid death.
- **DynamicSupervisor** — decouples session lifetime from the caller
  that asked for it. Without this, a LiveView calling `create` would
  link the Session to itself; LiveView dies → Session dies. Under the
  DynamicSupervisor, Sessions outlive their callers.

  Restart strategy is `:temporary`: sessions do **not** auto-restart on
  crash. Restarting a `:new` session would produce a new id (meaningless);
  restarting a `:load` session would silently discard mid-turn state.
  Better to let failures surface and have the app explicitly reopen.
- **Tracker** — maintains the live cross-session status feed. See
  "The Tracker" below.

### `:one_for_one` rationale

The three children are functionally independent:

- If Tracker crashes, running sessions keep running. Tracker restarts and
  re-observes them (see "Tracker recovery").
- If Registry crashes, in-flight `Session.prompt`/etc. calls made via
  `{:via, Registry, _}` names will fail, but already-established pids
  held by callers still work. Registry restarts empty; new session
  registrations populate it. Sessions registered under the previous
  instance are unreachable by name until they re-register (which they
  won't — sessions register once at startup).
- If DynamicSupervisor crashes, all running sessions die with it.

The Registry/DynamicSupervisor crash modes are severe but rare; treating
them as independent (rather than `:rest_for_one` cascading) avoids
cascade-killing healthy sessions on a Tracker glitch.

---

## Agent changes

A single addition: a new `:status` event.

### New event

```elixir
{:agent, pid, :status, :idle | :running | :paused}
```

Fires every time the Agent's `status` field transitions. Payload is the
new status atom. The Agent owns this field and is the authoritative
source; Session forwards the event verbatim.

### Why a dedicated event

The existing `:state` event fires only on `set_state/2,3` mutations — it
means "you mutated state externally, here's the new state." Extending it
to cover internal status transitions would blur that contract and make
change-detection consumers (Session's persistence path) process events
they don't care about.

`:status` is purely informational: "the agent's lifecycle phase changed."
Consumers that want a UI indicator (the Tracker, directly-subscribed
LiveViews) listen for `:status`. Consumers that care about mutations
(Session for persistence) keep listening for `:state`.

### Emission points

Status transitions happen in a small number of places in the Agent
server. Each transition wraps its state write with a `:status` emission:

- `:idle → :running` when a step is spawned at turn start or after a
  tool-result continuation.
- `:running → :idle` on `:turn {:stop, _}`, `:cancelled`, `:error`
  (after `handle_error` returns `{:stop, _}`).
- `:running → :paused` when `handle_tool_use` returns `{:pause, _, _}`
  or the equivalent mechanism.
- `:paused → :running` on `resume/2`.
- `:paused → :idle` on `cancel/1`.

No event when the status doesn't change (idempotent transitions are a
no-op). `:status` fires after the state is committed, before other
events that derive from the transition (e.g., a `:turn` commit fires
after its associated `:running → :idle`).

---

## Session changes

Three additions, all supporting the Manager model without breaking
standalone Session use:

1. Unified `subscribe/1,2` with `:controller | :observer` mode.
2. `:status` event forwarded from Agent.
3. `idle_shutdown_after` start option driving self-shutdown.

### Unified subscription with modes

Today Session has `subscribe/1,2` with no mode concept. Adding
controller/observer modes replaces that:

```elixir
Session.subscribe(session, opts \\ []) :: {:ok, Snapshot.t()}
# opts[:mode] :: :controller | :observer   (default :controller)
```

- **`:controller`** — receives all events AND counts toward keeping the
  session alive. The common case: a LiveView rendering the session, a
  CLI waiting for a turn to complete.
- **`:observer`** — receives all events, does not count toward keep-alive.
  For the Tracker, monitoring processes, loggers.

Both modes return the same Snapshot and receive the same event stream.
The difference is purely about lifetime: controllers prevent idle
shutdown, observers don't.

Subscription is **idempotent per pid**: calling `subscribe(session,
mode: X)` twice from the same pid results in one subscription with
mode X (the second call updates the mode). Calling with a different
mode updates in place — controller count increments/decrements as
appropriate. If the same pid genuinely wants two independent
subscriptions, it spawns two processes. This matches monitor semantics:
one subscription per ref per pid.

`unsubscribe/1,2` releases whichever mode was held. Monitor-based
cleanup fires on subscriber death, releasing the slot.

### Subscribe start options (Session)

Existing:
- `subscribe: true` — subscribes the caller of `start_link`.
- `subscribers: [pid]` — subscribes the given pids.

New semantics:
- Both default to `:controller` mode.
- Can be upgraded to per-pid control: `subscribers: [{pid, mode}]`
  accepts `pid` (implicit controller) or `{pid, mode}` (explicit).

Bare pids stay compatible with existing test code.

### `:status` event forwarding

Session forwards Agent `:status` events verbatim with its own tag:

```elixir
{:session, pid, :status, :idle | :running | :paused}
```

Session also uses `:status` internally to drive idle-shutdown evaluation
(see below).

### `idle_shutdown_after` and shutdown mechanics

New Session start option:

```elixir
:idle_shutdown_after :: non_neg_integer() | :infinity   # no default
```

When unset (or `:infinity`), the Session never self-shuts-down. When
set to an integer, the rule: when **controller count is 0** AND
**agent status is `:idle`**, Session schedules a `:idle_shutdown`
message after `idle_shutdown_after` ms. If either condition breaks
before the timer fires (a controller joins, agent goes running), the
timer is cancelled. When the timer fires with conditions still true,
Session calls `GenServer.stop(self(), :normal)`.

When `idle_shutdown_after = 0`, no timer is used — the shutdown is
performed synchronously in the handle clause that detects the condition.

Standalone Session callers default to unset (never shut down). The
Manager layer injects `idle_shutdown_after: 300_000` (its default) into
every session it starts, unless the caller or Manager config overrides.

#### Evaluation points

Shutdown is only evaluated on **transitions**, never at init:

- Controller count transitions to 0 (unsubscribe, mode change from
  `:controller` to `:observer`, controller pid death).
- Agent `:status` event with payload `:idle`.

Init deliberately does not evaluate. At init time the Session has
controllers = 0 and status = `:idle`, but no transition has occurred —
the Session simply exists. Shutdown only becomes a possibility once
something actually changes state in an unfavourable direction.

This gives the intuitive behaviour across use cases:

- **Bare Session, nobody subscribes, nobody prompts** — sits forever;
  no transitions occur.
- **Bare Session with controller, then controller leaves** — dies when
  the controller unsubscribes (controllers→0 evaluation; status is
  idle; shutdown).
- **Manager-managed Session** — caller is auto-subscribed as controller
  at create/open; runs while caller is alive; dies when caller dies or
  unsubscribes.
- **Bare Session prompted without any subscribers** — dies after the
  first turn completes (status→idle evaluation; no controllers). This
  is arguably correct: the caller didn't register interest in keeping
  it alive, so it shuts down when its work is done.

### Shutdown interaction with turns

The shutdown condition explicitly requires idle status. A session
running a turn with no controllers (e.g., controller died mid-turn)
will **not** shut down — the turn finishes, status goes idle, THEN
evaluation triggers shutdown. This preserves turn integrity; partial
turns are never abandoned due to idle-shutdown.

### State additions

New fields on the Session struct (internal):

- `:controllers` — `MapSet.t(pid)` — pids currently subscribed as
  controllers.
- `:observers` — `MapSet.t(pid)` — pids currently subscribed as
  observers.
- `:idle_shutdown_after` — configured timeout, stored for re-evaluation.
- `:shutdown_timer` — `reference | nil` — current `send_after` ref when
  the shutdown timer is pending.
- `:agent_status` — `:idle | :running | :paused` — cached from Agent
  `:status` events for shutdown evaluation.

The existing `subscribers` and `monitors` fields become the union of
controllers + observers, or we split and retire the old fields. Either
shape is fine; this is an implementation detail.

---

## The Tracker

A GenServer child of the Manager supervisor. Maintains an in-memory
projection of running sessions, exposes it synchronously, and fans out
live updates to Manager-level subscribers.

### State

```elixir
%{
  sessions:    %{session_id => %{id, title, status, pid}},
  subscribers: MapSet.t(pid),
  monitors:    %{reference => pid}       # subscriber and session monitors
}
```

One entry per running session. `status` is the Agent's status as of the
last observed event; `title` is the Session's current title. `pid` is
the Session pid (not the Agent's — callers who want the Agent get it
via `Session.get_agent(pid)`).

### Event flow

1. Manager calls `Tracker.add(id, pid)` synchronously inside its
   `create`/`open` handling, **before** returning the pid to the
   caller. This ensures every session visible to callers is visible to
   the Tracker.
2. Tracker monitors the pid (cleanup on death) and subscribes to the
   session as `:observer` — so the Tracker's subscription does not
   prevent idle shutdown.
3. Tracker's initial entry is built from `Session.get_snapshot/1`:
   `{id, title, status}` taken atomically at subscription time.
4. On incoming session events (forwarded because Tracker is a subscriber):
   - `:status` → update `status`, broadcast `:session_status`.
   - `:title` → update `title`, broadcast `:session_title`.
   - `:DOWN` (monitor) → remove entry, broadcast `:session_removed`.
5. Other Session events (`:turn`, `:tree`, etc.) are ignored.

### Pub/sub

```elixir
Manager.subscribe(opts \\ []) :: {:ok, Tracker.Snapshot.t()}
Manager.unsubscribe() :: :ok
```

The snapshot is a list of `%{id, title, status, pid}` maps, one per
currently-running session, captured atomically at subscribe time. After
subscription, the caller receives:

```elixir
{:manager, pid, :session_added,   %{id, title, status, pid: session_pid}}
{:manager, pid, :session_status,  %{id, status}}
{:manager, pid, :session_title,   %{id, title}}
{:manager, pid, :session_removed, %{id}}
```

Subscribers are monitored and cleaned up on death. No filtering by id —
consumers filter client-side if they only care about specific sessions.

### Recovery

On Tracker crash and restart (supervised restart), the Tracker's state
is empty. It rebuilds by:

1. Enumerating `Registry.select` for the Manager's Registry, yielding
   all `{id, pid}` pairs of currently-running sessions.
2. For each, re-subscribing as `:observer` and capturing the snapshot.

Manager-level subscribers lose their subscriptions when the Tracker dies
(Tracker is the subscription owner). They must re-subscribe. This is
documented behaviour; the Tracker crashing is rare and the rebuild is
fast.

### List_running

```elixir
Manager.list_running() :: [%{id, title, status, pid}]
```

A synchronous `GenServer.call` into the Tracker returning its current
map as a list. Ordering is unspecified (map iteration order). Callers
sort client-side.

### Why not subscribe sessions to the Tracker by observation of Registry?

We could have the Tracker observe Registry changes and auto-discover new
sessions. But Registry's notification model is listener-based and
requires the Tracker to be a registered listener at Registry startup
time, adding a coupling. The explicit `Tracker.add` pattern keeps the
Manager in charge of "what's tracked" and makes the hand-off race-free
relative to Manager.create/open return.

---

## Public API

### Lifecycle

```elixir
Manager.create(opts \\ [])       :: {:ok, pid} | {:error, reason}
Manager.open(id, opts \\ [])     :: {:ok, pid} | {:error, :not_found} | {:error, reason}
Manager.close(id)                :: :ok
Manager.delete(id)               :: :ok | {:error, reason}
```

- **`create/1`** — starts a fresh session. Accepts `:id` for an explicit
  id, otherwise generates one (22-char URL-safe base64, as in Session).
  Auto-subscribes the caller as controller. Errors if the id already
  exists in the store OR is already running under the same Manager.
- **`open/2`** — returns a pid for the given session id:
  - Not in store → `{:error, :not_found}`.
  - In store, not running → start process via DynamicSupervisor with
    `load: id`, auto-subscribe caller as controller, return pid.
  - Already running → subscribe caller as controller, return existing
    pid. Opts are silently ignored in this branch (document clearly).
- **`close/1`** — stops the running process via `Session.stop/1`; the
  store is untouched. Idempotent: if not running, returns `:ok`.
- **`delete/1`** — stops if running, then `Store.delete(store, id, [])`.
  Returns `:ok` or propagates the store error. Order: stop first, then
  delete, so no writer races the delete.

### Discovery

```elixir
Manager.whereis(id)          :: pid | nil
Manager.list(opts \\ [])     :: {:ok, [session_info]} | {:error, reason}
Manager.list_running()       :: [%{id, title, status, pid}]
```

- **`whereis/1`** — Registry lookup. Matches `Process.whereis/1` shape.
- **`list/1`** — passes through to `Store.list(store, opts)` with no
  default limit. Callers who want pagination set `:limit`/`:offset`.
- **`list_running/0`** — Tracker's current map. For sidebar rendering
  combined with `list/1` for "all sessions with running indicator":

    ```elixir
    all_sessions = Manager.list(limit: 50)
    running = Manager.list_running() |> Map.new(fn m -> {m.id, m} end)
    Enum.map(all_sessions, fn s -> Map.merge(s, Map.get(running, s.id, %{})) end)
    ```

### Manager-level pub/sub

```elixir
Manager.subscribe(opts \\ [])    :: {:ok, Tracker.Snapshot.t()}
Manager.unsubscribe()            :: :ok
```

Described under "The Tracker" above.

### Auto-subscribe on create/open

Both `create/1` and `open/2` auto-subscribe the caller as controller by
default. Opt out with `subscribe: false`:

```elixir
Manager.create(subscribe: false)    # caller is not a controller
Manager.open(id, subscribe: false)  # same
```

With `subscribe: false` (and no other controllers ever subscribing),
the session won't idle-shutdown, because shutdown evaluation only
triggers on transitions — with no controller ever joining, the
controller count never transitions from non-zero to zero. The session
runs until explicit close/delete. This is the correct behaviour: the
caller explicitly opted out of lifetime management.

Mechanics: Manager captures `self()` at API entry and injects it into
the Session's `subscribers:` start opt (for `create`) or calls
`Session.subscribe(pid, mode: :controller)` on the loaded/existing
session (for `open`). The caller becomes a real controller before
Manager returns.

---

## Options flowing to Session

Manager.create and Manager.open build the opts passed to
`Session.start_link` in this order:

1. **Manager-owned opts**, rejected at the Manager boundary with an
   error if supplied by the caller:
   - `:store`, `:name`, `:new`, `:load`
2. **Manager-level defaults** applied first:
   - `:store` injected from Manager config.
   - `:idle_shutdown_after` from Manager config (falling back to
     `300_000` when Manager config doesn't set it); caller's value
     overrides.
3. **Pass-through caller opts** — `:title`, `:subscribe`,
   `:subscribers`, plus any Session-level opt not covered above.
4. **Injected by Manager** at the end:
   - `:new` (with `:id` if supplied) or `:load` (with the given id),
     based on which API function was called.
   - `:subscribers: [caller_pid]` when `subscribe: true` (default).

Session's own validation applies to the final opts.

---

## Events

Session's existing events (including the new `:status`) remain
unchanged. Manager adds its own event namespace:

```elixir
{:manager, manager_pid, :session_added,   %{id, title, status, pid}}
{:manager, manager_pid, :session_status,  %{id, status}}
{:manager, manager_pid, :session_title,   %{id, title}}
{:manager, manager_pid, :session_removed, %{id}}
```

`manager_pid` is the pid of the Tracker (which is also the subscription
owner — subscriptions die with it). Using the Tracker pid (rather than
the Supervisor pid) lets consumers distinguish events cleanly across
multiple Managers.

### Ordering

- `:session_added` fires after the Tracker has the entry — after
  `Manager.create/open` returns a pid to its caller.
- `:session_status` follows the underlying Agent status transition.
- `:session_title` follows the underlying Session title change.
- `:session_removed` fires on session process DOWN, regardless of
  cause (close, delete, crash, idle-shutdown).

No guarantees across sessions: events from two different sessions may
interleave arbitrarily.

---

## Lifecycle and races

### Session start from Manager

```
1. Manager.create(opts) called from caller C.
2. Manager captures C = self() at entry.
3. Manager validates opts, rejects Manager-owned keys.
4. Manager injects Manager-level store and idle_shutdown_after
   (with 300_000 fallback), applies caller overrides, builds final opts.
5. Manager calls DynamicSupervisor.start_child/2 with the Session
   start spec, using `{:via, Registry, {reg, id}}` as the name, and
   `subscribers: [C]` so C subscribes as controller during Session init.
6. Session starts with C already present as a controller.
7. Manager calls Tracker.add(id, pid) synchronously.
8. Manager returns {:ok, pid} to the caller.
```

By step 8, the caller has a pid; the Tracker has an entry; the Session
has a controller. Any Manager-level subscriber receives
`:session_added` before step 8 returns.

### Session already running on open

```
1. Manager.open(id) called from caller C.
2. Manager captures C = self().
3. Manager does DynamicSupervisor.start_child/2 with load: id.
4. start_child returns {:error, {:already_started, pid}}.
5. Manager converts to {:ok, pid}, then calls
   Session.subscribe(pid, mode: :controller) passing C as the pid.
6. Manager returns {:ok, pid}.
```

The Tracker already has an entry from when the session was first
started, so no `:session_added` fires on this second open.

### Session idle-shutdown while caller still alive

- Caller C does `create`, receives pid, is subscribed as controller.
- C does its work, then does `Session.unsubscribe(pid)`.
- Session's controllers count drops to 0. Agent is idle.
  `idle_shutdown_after` timer starts; when it fires (default 5 min),
  Session stops. If another controller subscribes before the timer
  fires, the timer cancels.
- Tracker observes DOWN, broadcasts `:session_removed`.
- C's pid reference is now stale. Future calls against it return
  `{:exit, :noproc}`. C should use `Manager.open(id)` if it wants to
  reattach.

### Tracker crash during active session

- Tracker crashes mid-session.
- Manager supervisor (`:one_for_one`) restarts Tracker.
- Tracker init enumerates Registry, re-subscribes to all running
  sessions as observer, rebuilds state from each `Session.get_snapshot`.
- Manager-level subscribers had their subscriptions die with the old
  Tracker pid. They must re-subscribe. No automatic re-subscription
  in v1.

### Concurrent `Manager.open` calls on the same not-running id

Two callers call `open("abc")` simultaneously for a session that's in
the store but not running. Expected behaviour:

- Both `DynamicSupervisor.start_child` calls race.
- One wins, starts the Session, registers it.
- The loser gets `{:error, {:already_started, pid}}` which Manager
  converts to `{:ok, pid}` — pointing to the same pid as the winner.
- Both callers end up subscribed as controllers on the same Session.

This is consistent: both callers asked for the same session, both got
it, both hold it alive. If they both unsubscribe, the session shuts
down.

### Concurrent `Manager.create` with explicit id

Two callers call `create(id: "abc")` simultaneously:

- First `start_child` succeeds (nothing in store, nothing registered).
- Second `start_child` fails with `{:already_started, pid}`.
- Manager returns `{:error, :already_exists}` for the loser.

`create` does not adopt the existing process. The caller asked for a
*new* session with id "abc" — if that id is taken, that's an error.

The duplicate-id race in the store (two `start_link(new: _)` calls on
the same id with nothing registered yet) is documented in
`session-design.md` as a known edge case; the Manager cannot fully
resolve it without an adapter-level `create_if_absent` primitive.

---

## Validation & errors

| Return | Situation |
|---|---|
| `{:error, :already_exists}` | `create(id: "x")` when id is in store or running |
| `{:error, :not_found}` | `open(id)` when id not in store |
| `{:error, :invalid_opt, key}` | Manager-owned key (`:store`, `:name`, `:new`, `:load`) passed to `create`/`open` |
| `{:error, reason}` from Session | forwarded verbatim |
| `{:error, reason}` from Store | forwarded verbatim on `delete/1` |

`close/1` never errors. `whereis/1` returns `nil` for unknown ids.

---

## Parked / future work

Deliberately excluded from the initial Manager implementation:

### Manager-level subscription filtering

`subscribe(ids: [id1, id2])` to only receive events for specific
sessions. Client-side filtering works for v1; adding server-side
filtering is a performance optimisation to consider later.

### Automatic Manager-subscriber resubscription on Tracker restart

Currently Manager-level subscribers must re-subscribe after a Tracker
crash. An automatic re-subscription mechanism is possible but
non-trivial (the Manager would need to keep subscriber state out of the
Tracker, complicating the "derivable state" property).

### Cross-node / distributed Manager

All primitives here (Registry, DynamicSupervisor, Tracker) are single-
node. A distributed variant is a separate design exercise.

### Session title generation

A follow-up to the parked `auto_title:` idea in `session-design.md`.
Manager could provide a convenience that subscribes on `:turn` and
generates a title. Parked until demand surfaces.

### Per-session metadata in Tracker

Apps wanting to surface more than `{id, title, status, pid}` in their
sidebar UI need richer per-session data. Options: a `:data` field on
Agent state (already parked), or Tracker-level arbitrary fields the app
can attach. Deferred.

---

## Open questions

Items worth revisiting during implementation:

1. **Explicit-id collision check semantics.** `create(id: "x")` on a
   running `"x"` is clearly `{:error, :already_exists}`. `create(id:
   "x")` on an id present in the store but not running is the
   interesting case: should Manager refuse (caller asked for *new*;
   that id is taken) or adopt (load the existing)? The doc proposes
   refuse, matching "new means new." Confirm in implementation tests.
   Auto-generated ids (`create()` with no `:id`) skip the check —
   128-bit entropy makes collision impossible in practice.

2. **Tracker snapshot atomicity across Session snapshots.** When the
   Tracker subscribes to N sessions on restart, each `get_snapshot` is
   atomic, but the N-way composition is not — two sessions' `:status`
   events could interleave with the rebuild. Acceptable for a rare
   restart; flag for test coverage.

3. **`Manager.list_running/0` vs `Manager.subscribe/0` consistency.** Both
   read from the Tracker, but `list_running` is a synchronous call and
   `subscribe` returns a snapshot atomically. If a consumer calls
   `list_running` then `subscribe` in quick succession, they may get
   slightly different views (a session added in between). Document as
   "consistency is per-call, not across calls."

4. **Telemetry / observability.** Manager operations (create, open,
   delete) are good telemetry-emission points. Deferred to a dedicated
   observability pass, but flag for spec update when added.

---

## Implementation phases

This design changes three modules (Agent, Session, Manager). The phases
below can land as separate PRs with tests; dependencies flow in order.

### Phase 9a — Agent and Session foundations

**Goal:** add the Agent `:status` event, unified Session subscription
with modes, `:idle_shutdown_after` and shutdown mechanics, `:status` event
forwarding.

**Key work:**

- `Omni.Agent` emits `{:agent, pid, :status, s}` on every status
  transition (`:idle`/`:running`/`:paused`).
- `Omni.Session.subscribe/1,2` gains `mode: :controller | :observer`
  option (default `:controller`). Per-pid idempotency; mode updates
  in-place.
- `Omni.Session` accepts `subscribers: [pid | {pid, mode}]` start opt
  shape; bare pids default to `:controller`.
- `Omni.Session` forwards Agent `:status` events as session events with
  the same tag.
- `Omni.Session` gains `idle_shutdown_after` start opt
  (`non_neg_integer() | :infinity`, no default — unset means never
  shut down) and implements the controllers-zero + idle evaluation on
  transitions, with a cancellable timer when the value is a positive
  integer.
- Session struct gains `controllers`, `observers`, `agent_status`,
  `shutdown_timer` fields (internal).
- Tests cover: status event emission and forwarding; controller/observer
  mode subscribe and unsubscribe; idempotent subscribe-same-pid; mode
  change on second subscribe; init does not evaluate shutdown;
  shutdown on controllers-zero-idle with grace 0; shutdown deferral
  while agent running; shutdown cancellation on new controller join
  during the grace window.

**Dependencies:** Phases 1–8 (current main).

**Acceptance:**

- Bare Session can subscribe controllers and observers; idle-shutdown
  fires only on transitions that satisfy controllers-zero + idle,
  never at init.
- Existing Session tests (Phase 7–8) pass unchanged — defaults preserve
  the current behaviour for callers that never subscribe or subscribe
  without specifying mode.

### Phase 9b — Manager core (Supervisor + Registry + DynamicSupervisor)

**Goal:** ship `Omni.Session.Manager` as a `use`-pattern module, with
lifecycle and discovery APIs. No Tracker yet — the Manager supports
create/open/close/delete/whereis/list; `list_running` and `subscribe` are
deferred to 9c.

**Key work:**

- `Omni.Session.Manager` as a Supervisor child with `:one_for_one`
  strategy, starting Registry and DynamicSupervisor.
- `use Omni.Session.Manager` macro generating the delegation module.
- `start_link/1` accepting `:name`, `:store`, `:idle_shutdown_after`.
- Public API: `create/2`, `open/3`, `close/2`, `delete/2`, `whereis/2`,
  `list/2` — each taking the module ref as first arg, with the
  generated shorthand.
- Caller auto-subscribe as controller via `subscribers:` opt injection
  at create time and explicit `Session.subscribe` call at open time.
- Tests: create and open flows; already-running on open; id collision
  on create with explicit id; close idempotency; delete stops-then-
  deletes; opt filtering; `idle_shutdown_after` Manager default (300_000),
  Manager-config override, per-call override, `:infinity` opt-out;
  multiple concurrent Managers by module name.

**Dependencies:** Phase 9a.

**Acceptance:**

- Can define `MyApp.Sessions`, add to supervision tree, and use it for
  multi-session lifecycle without touching Session internals.
- Restart `MyApp.Sessions` — running sessions die (DynamicSupervisor
  children are `:temporary`), Registry resets. Re-open with `load: id`
  works on a fresh Manager.

### Phase 9c — Tracker and Manager-level pub/sub

**Goal:** add the Tracker child and Manager-level subscribe.

**Key work:**

- `Omni.Session.Manager.Tracker` GenServer added as the third Manager
  child.
- Manager `create`/`open` calls `Tracker.add(id, pid)` synchronously
  before returning.
- Tracker observes sessions as `:observer` mode, maintains state map,
  monitors pid death.
- Manager-level pub/sub: `subscribe/1`, `unsubscribe/1`, atomic snapshot
  at subscribe time.
- Event broadcast: `:session_added`, `:session_status`, `:session_title`,
  `:session_removed`.
- `Manager.list_running/1` exposing Tracker's current map.
- Tracker recovery on restart: enumerate Registry, re-subscribe, rebuild
  state.
- Tests: Tracker entry on create and open; event delivery to
  subscribers; `:session_removed` on close / delete / crash / idle-
  shutdown; Tracker crash and rebuild; `list_running` consistency.

**Dependencies:** Phase 9b.

**Acceptance:**

- A UI sidebar can `subscribe` and render a live list of sessions,
  tracking status changes across all of them.
- Manager-level subscribers receive events for every session lifecycle
  transition, from any caller.
- Tracker crash and restart recovers state without losing any running
  sessions (subscribers resubscribe).

---

## Beyond Phase 9

Candidates for further work, in priority-ish order:

- **Session title auto-generation helpers** (parked in
  `session-design.md`). With Manager in place, this becomes an obvious
  add.
- **Distributed Manager** — cross-node Registry, cross-node Tracker
  pub/sub. Requires a design exercise of its own.
- **Observability** — telemetry events at Manager boundaries, opt-in
  metrics.
- **Per-session Tracker metadata** — app-attachable fields on the
  Tracker's session map, for richer sidebar UI.

Deferred until the phases above are in hand and concrete demand has
shown up.
