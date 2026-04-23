# Omni Agent — Package Design

This is the single reference for how `omni_agent` is built. It covers
the whole stack — Agent, Session, Store, Manager — at the level of
detail needed to work inside the package without rediscovering the
design from code.

If you are extending or refactoring, start here. `CLAUDE.md` complements
this document with developer conventions and workflows but defers to
this file for architecture.

---

## 1. What the package is

Omni Agent provides OTP building blocks for stateful, long-running LLM
interactions on top of [`omni`](https://github.com/aaronrussell/omni)
— the stateless LLM API layer.

The package is layered. Each layer depends only on the one below, uses
only the lower layer's public API, and can be used standalone:

```
Omni.Session.Manager   — supervises many sessions, id lookup, cross-
                         session view. Optional.
       │
Omni.Session           — conversation lifetime: identity, branching
                         message tree, persistence, navigation.
       │
Omni.Agent             — turn engine: model, context, tools, events.
                         No identity, no persistence.
       │
Omni (stateless)       — stream_text / generate_text / Tool.Runner /
                         message structs / content blocks.
```

Three temporal scopes map onto the three `omni_agent` layers:

- **Agent** — ephemeral, one **turn** at a time. Source of truth for
  in-flight state.
- **Session** — longer-lived, one **conversation** across turns. Source
  of truth for at-rest state between turns.
- **Manager** — process-tree-wide, many concurrent sessions. Source of
  truth for discovery and cross-session status.

---

## 2. Relationship to `omni`

`omni_agent` depends on `omni`; `omni` has no knowledge of
`omni_agent`. Integration points are small:

- `Omni.stream_text/3` — the sole LLM request path (used by
  `Omni.Agent.Step`).
- `Omni.Tool.Runner.run/3` — parallel tool execution (used by
  `Omni.Agent.Executor`).
- `Omni.{Context, Message, Model, Response, Tool, Usage}` — data structs.
- `Omni.Content.{Text, Thinking, ToolResult, ToolUse}` — content blocks.
- `Omni.Codec` — message/usage JSON encoding for store adapters.

The Agent does **not** use `Omni.Loop` for tool execution. It calls
`stream_text` with `max_steps: 1`, manages tools itself between
requests, and enables per-tool approval and pause/resume — capabilities
Loop's stateless design cannot support.

---

## 3. Process topology

A running session under a manager looks like:

```
  MyApp.Sessions (Supervisor, :rest_for_one)
  ├── MyApp.Sessions.Registry (Registry, keys: :unique)
  ├── MyApp.Sessions.DynamicSupervisor (:one_for_one, :temporary children)
  │     └── Omni.Session  (named via Registry by id)
  │           └── Omni.Agent.Server (linked, via start_link)
  │                 ├── Omni.Agent.Step     (linked Task, per step)
  │                 └── Omni.Agent.Executor (linked Task, per tool batch)
  │                       └── Tool Tasks (one per tool, from Tool.Runner)
  └── MyApp.Sessions.Tracker (GenServer, :observer-subscribes each session)
```

The Agent GenServer never blocks on IO. All blocking work lives in
linked Tasks, so the server remains responsive for cancel, resume,
state inspection, and steering at all times.

Session links the Agent. Agent crashes propagate up (no `trap_exit`) —
an unhealthy Agent takes the Session with it. Sessions are cheap to
reopen via `load:`.

Under a Manager, sessions live under the DynamicSupervisor with
`restart: :temporary`: they do not auto-restart on crash, because a
fresh `:new` session would get a new id (meaningless) and a restarted
`:load` would silently discard mid-turn state. Let failures surface.

---

## 4. Agent

`Omni.Agent` is a GenServer that owns a model, a context (system
prompt, messages, tools), and user-defined private state. Callers send
prompts in; the agent streams events back. Lifecycle callbacks control
continuation, tool approval, and error handling.

### 4.1 State

Split into a public `%Omni.Agent.State{}` passed to all callbacks and
an internal `%Omni.Agent.Server{}` struct holding GenServer machinery.

Public state (`lib/omni/agent/state.ex`):

```elixir
%Omni.Agent.State{
  model:    Omni.Model.t(),
  system:   String.t() | nil,
  messages: [Omni.Message.t()],
  tools:    [Omni.Tool.t()],
  opts:     keyword(),
  private:  map(),
  status:   :idle | :running | :paused,
  step:     non_neg_integer()
}
```

Two logical tiers:

- **Configuration** (`model`, `system`, `messages`, `tools`, `opts`):
  set at start, replaceable via `set_state/2,3` when idle.
- **Session state** (`private`, `status`, `step`): changes during
  operation. `private` is for callback-module runtime state (PIDs,
  refs, closures) — not settable via `set_state`, mutated via
  `%{state | private: _}` inside callbacks.

`state.messages` is **committed-only**. In-flight segment messages
live in the internal server struct as `turn_messages` until committed
at a `:turn` event. `state.messages` always ends with an assistant
message containing no `ToolUse` blocks, or is empty — an invariant
enforced at turn boundaries and re-enforced at `set_state(:messages,
...)` and the state returned from `init/1`.

### 4.2 Turn lifecycle

Three levels:

- **Step** — one LLM request-response cycle. Calls `stream_text` with
  `max_steps: 1`. If the model emits tool uses, the agent handles them
  and launches another step.
- **Segment** — one natural stop by the model. A `:turn` event
  (`{:stop, _}` or `{:continue, _}`) commits the segment's messages.
- **Turn** — starts with `prompt/3`, ends with `:turn {:stop, _}` or
  `:cancelled` / `:error`.

A turn may contain multiple segments (via `handle_turn` returning
`{:continue, content, state}`) and each segment may contain multiple
steps (if the model called tools).

**Commit semantics.** In-flight messages accumulate in `turn_messages`.
On every `:turn` event, `turn_messages` commit to `state.messages` —
both `{:continue, _}` and `{:stop, _}` are valid stopping points. On
`:cancelled` or `:error`, they are discarded; `state.messages` stays
untouched.

The single `evaluate_head/1` function drives the state machine on
`turn_messages`:

| Last message in `turn_messages` | Action |
|---|---|
| User | spawn Step |
| Assistant with `ToolUse` blocks | enter tool decision phase |
| Assistant without `ToolUse` blocks | call `handle_turn` |

### 4.3 Tool decision flow

When a step yields an assistant with tool uses:

1. **Decision phase (synchronous, in-GenServer).** `handle_tool_use/2`
   is called sequentially for each tool use. Returns:
   - `{:execute, state}` — queue for the execution phase.
   - `{:reject, reason, state}` — error `ToolResult` recorded, tool
     never runs.
   - `{:result, result, state}` — supply a `ToolResult` directly, skip
     execution.
   - `{:pause, reason, state}` — stop collecting decisions, agent
     transitions to `:paused`, emits `:pause`, waits for `resume/2`.
2. **Handler gap check.** If any approved tool is missing from the
   tool map (a hallucinated name) or has a `nil` handler,
   `handle_turn` fires with `stop_reason: :tool_use` — giving the
   callback module a chance to respond manually or stop cleanly.
3. **Execution phase (async, in Executor Task).** Approved tools run
   in parallel via `Tool.Runner.run/3`. Results (executed, rejected,
   provided) flow through `handle_tool_result/2`, then get sent to the
   model as a single user message for the next step.

### 4.4 Callbacks

All optional with `defoverridable` defaults.

```elixir
@callback init(State.t())                      :: {:ok, State.t()} | {:error, term()}
@callback handle_turn(Response.t(), State.t()) :: {:stop, State.t()}
                                                 | {:continue, term(), State.t()}
@callback handle_tool_use(ToolUse.t(), State.t())
            :: {:execute, State.t()}
             | {:reject, term(), State.t()}
             | {:result, ToolResult.t(), State.t()}
             | {:pause, term(), State.t()}
@callback handle_tool_result(ToolResult.t(), State.t()) :: {:ok, ToolResult.t(), State.t()}
@callback handle_error(term(), State.t())      :: {:stop, State.t()} | {:retry, State.t()}
@callback terminate(term(), State.t())         :: term()
```

- `init/1` receives the fully-resolved state (start opts merged, model
  resolved). Returns a possibly-modified state; the `:messages`
  invariant is checked on return.
- `handle_turn/2` fires when a step completes without executable tool
  uses. `response.stop_reason` is `:stop | :tool_use | :length |
  :refusal`.
- `handle_error/2` fires for step-level failures that the agent can
  recover from: `stream_text` returning `{:error, reason}` (HTTP
  errors, network failures, bad responses), and the Step Task
  crashing (`{:step_crashed, reason}`). `:length` and `:refusal` are
  not errors — they surface via `handle_turn`. Executor Task crashes
  **bypass** `handle_error` and go straight to a terminal `:error`
  event — tool execution is more opaque to the agent, so recovery via
  retry isn't meaningful there.

### 4.5 Public API

```elixir
# Lifecycle
Omni.Agent.start_link(opts)                      # no callback module
Omni.Agent.start_link(module, opts)              # with callback module
use Omni.Agent                                   # generates start_link/1 delegate

# Turn control
Omni.Agent.prompt(agent, content, opts \\ [])    # start a turn or steer
Omni.Agent.resume(agent, decision)               # :execute | {:reject, reason} | {:result, result}
Omni.Agent.cancel(agent)

# Inspection
Omni.Agent.get_state(agent)
Omni.Agent.get_state(agent, key)
Omni.Agent.get_snapshot(agent)                   # %Snapshot{state, pending, partial}

# Mutation (idle only)
Omni.Agent.set_state(agent, opts)                # replace fields atomically
Omni.Agent.set_state(agent, field, value_or_fun) # replace or transform

# Subscription
Omni.Agent.subscribe(agent)        # {:ok, %Snapshot{}}
Omni.Agent.subscribe(agent, pid)
Omni.Agent.unsubscribe(agent)
Omni.Agent.unsubscribe(agent, pid)
```

Start options of note:

- `:model` (required), `:system`, `:messages`, `:tools`, `:opts`,
  `:private`
- `:tool_timeout` (default 5000ms) — per-tool execution timeout,
  applied uniformly
- `:subscribe` (boolean) / `:subscribers` (list of pids)
- GenServer keys (`:name`, `:timeout`, `:hibernate_after`, `:spawn_opt`,
  `:debug`) are extracted from the flat opt list and passed to
  `GenServer.start_link/3`.

`set_state` accepts `:model | :system | :messages | :tools | :opts`.
Not `:private` (callback-owned), not `:status` / `:step` (framework).
All values replace — there is no merge. Returns `{:error, :running}`
if not idle, `{:error, :invalid_messages}` on invariant violation,
`{:error, {:model_not_found, ref}}` if a model can't resolve.

There is no `regenerate/1` primitive — callers do `set_state(:messages,
_)` + `prompt/3`. Session uses exactly this pattern for its `branch/2`.

### 4.6 Events

All events are delivered as `{:agent, pid, type, payload}` via `send/2`
to subscribers. A subscriber set is a `MapSet` of pids with monitors
for cleanup on death.

**Streaming events** (forwarded from each step's `stream_text` output):

```
:text_start / :text_delta / :text_end
:thinking_start / :thinking_delta / :thinking_end
:tool_use_start / :tool_use_delta / :tool_use_end
```

**Lifecycle events**:

```
:message       %Message{}                           # msg appended to turn_messages
:tool_result   %ToolResult{}                        # one per tool (executed / rejected / provided)
:step          %Response{messages: [user, asst]}    # step completed
:turn          {:continue, %Response{}}             # segment committed, turn continues
:turn          {:stop, %Response{}}                 # turn ended, agent idle
:pause         {reason, %ToolUse{}}                 # waiting on resume/2
:retry         reason                               # handle_error returned :retry
:cancelled     %Response{stop_reason: :cancelled}   # cancel/1 invoked; turn_messages discarded
:error         reason                               # handle_error returned :stop; turn_messages discarded
:state         %State{}                             # set_state mutation applied
:status        :idle | :running | :paused           # lifecycle phase changed
```

**Key contracts:**

- `:message` fires whenever a message is appended to the in-flight
  segment:
  - For the **assistant** response, after all streaming deltas for
    that message and before `:step`.
  - For **user-role** messages (initial prompt, continuation prompt,
    tool-result user), as soon as the message is constructed — no
    streaming precedes them.
- `:step.response.messages` is always exactly `[user, assistant]` —
  the user message that prompted the step (initial prompt, continuation
  prompt, or tool-result user) and the assistant response.
- `:turn.response.messages` contains only the segment's messages
  (not the full turn's). Usage on `:turn` is segment-scoped — the Agent
  resets `turn_usage` per segment so multi-segment turns don't
  double-count.
- `:status` fires on every status transition and always precedes the
  event that caused the transition (e.g. `:status :idle` before `:turn
  {:stop, _}`). Idempotent transitions do not emit.
- `:state` fires only on `set_state/2,3` mutations — not on
  turn-boundary commits (that's `:turn`). This separation lets
  consumers (Session's persistence path) distinguish externally-driven
  changes from internal progress.

### 4.7 Pub/sub and snapshot

`subscribe/1,2` is a `GenServer.call` that atomically adds the pid to
the subscriber set, monitors it, and returns
`{:ok, %Omni.Agent.Snapshot{state, pending, partial}}`:

```elixir
%Omni.Agent.Snapshot{
  state:   %State{},               # committed state
  pending: [%Message{}],           # turn_messages at snapshot time
  partial: %Message{} | nil        # currently streaming assistant, or nil
}
```

Compose the full view as `state.messages ++ pending ++
List.wrap(partial)`. Because subscribe + snapshot is handled in one
`handle_call` clause, no event can fire between the snapshot and the
subscriber being registered — late joiners align cleanly with the
live stream.

The Agent does not provide replay, resume-from-sequence, or
cross-lifetime continuity. Those are Session / Store concerns.

### 4.8 Pause / resume

Pause exists for one purpose: tool-use approval. Only `handle_tool_use`
can return `{:pause, reason, state}`.

On pause, status goes `:paused`, `:pause {reason, tool_use}` fires,
and the decision loop suspends. `resume/2` with `:execute` /
`{:reject, reason}` / `{:result, result}` records that outcome and
resumes iterating remaining decisions.

Subscribers see `:status :paused` before `:pause`.

### 4.9 Steering (prompt queuing)

A `prompt/3` call while `:running` or `:paused` does not error — it
stages the content as the next turn's prompt. At the upcoming `:turn`
event:

- `handle_turn` fires as normal (for bookkeeping).
- The staged prompt overrides `handle_turn`'s decision — whatever the
  callback returned, the agent continues with the staged content.

Repeated `prompt/3` calls replace the staged content — last-one-wins.

### 4.10 Inference opts

`state.opts` holds agent-level defaults (`:temperature`, `:max_tokens`,
`:max_steps`, etc.). Per-prompt opts passed to `prompt/3` merge on top
for that turn only. `max_steps` caps total LLM requests across the
turn; when hit, `handle_turn` still fires (callbacks can observe the
cap), but a `{:continue, _, _}` return is overridden to a stop so the
turn ends cleanly.

---

## 5. Session

`Omni.Session` is a GenServer wrapping a single linked `Omni.Agent`.
It owns a session id, a title, a branching message tree, and a store
adapter. It forwards Agent events to its own subscribers and commits
turn messages into the tree.

### 5.1 State

```elixir
%Omni.Session{
  id:                   String.t(),
  title:                String.t() | nil,
  tree:                 %Omni.Session.Tree{},
  store:                {module(), keyword()},
  agent:                pid(),
  subscribers:          MapSet.t(pid()),   # everyone who receives events
  controllers:          MapSet.t(pid()),   # subset: keeps the session alive
  monitors:             %{reference => pid()},
  agent_status:         :idle | :running | :paused,   # cached from :status events
  idle_shutdown_after:  non_neg_integer() | nil,
  shutdown_timer:       reference() | nil,
  last_persisted_state: map() | nil,       # change-detection scaffold
  regen_source:         Omni.Session.Tree.node_id() | nil
}
```

Notably absent: no `meta` field, no mirror of Agent's `model` /
`system` / `opts`. Agent config lives on the Agent; Session only caches
`last_persisted_state` (the persistable subset) for change detection.

### 5.2 Tree

`Omni.Session.Tree` is a pure-data module. One node per message —
assistant, user, and tool-result messages are all separate nodes. Turn
grouping is a projection the UI/app computes.

```elixir
%Omni.Session.Tree{
  nodes:   %{node_id() => %{id, parent_id, message, usage}},
  path:    [node_id()],                # active root-to-head path
  cursors: %{node_id() => node_id()}   # parent → last-active child
}
```

- **Auto-assigned integer ids** (`map_size(nodes) + 1` at push time).
  External callers never construct ids.
- **Append-only**: navigation and branching change `path`, not the
  node set.
- **Cursors** remember which child was active under a parent. `push`
  sets one cursor (parent → newly-pushed child); `navigate/2` sets
  cursors for every parent → child pair along the path from root to
  target. Both leave the tree in a state where `extend/1` from any
  ancestor reproduces the current active path.
- `extend/1` walks from the current head to a leaf, following cursors
  where present and falling back to the last (most recent) child
  otherwise.
- Empty `path` is valid — allows multiple disjoint roots on a single
  tree.

Usage is attached to the segment's last assistant node. `Tree.usage/1`
sums usage across the full node set (not just the active path).

### 5.3 Start modes

```elixir
Session.start_link(
  new: :auto | binary(),    # fresh session
  # OR
  load: binary(),           # load existing by id
  agent: [...] | {mod, [...]},     # required — Agent start opts
  store: {module, keyword()},       # required
  title: String.t(),                # new-mode only
  subscribe: true,                  # caller becomes :controller
  subscribers: [pid | {pid, :controller | :observer}],
  idle_shutdown_after: non_neg_integer() | nil
)
```

- No `:new` and no `:load` → implicit `new: :auto`.
- Both `:new` and `:load` → `{:error, :ambiguous_mode}`.
- Explicit `new: "binary-id"` that already exists in the store →
  `{:error, :already_exists}`. `new: :auto` skips this check (128
  bits of entropy make collision effectively impossible).
- `new:` with `agent: [messages: _]` → `{:error,
  :initial_messages_not_supported}`. The tree is the sole entry point
  for committed messages.

Auto-generated ids: `:crypto.strong_rand_bytes(16) |>
Base.url_encode64(padding: false)` (22 chars, URL-safe).

### 5.4 Load-mode resolution

When `load: id` is given and the store returns persisted state, each
Agent config field reconciles against start opts:

| Field | Resolution |
|---|---|
| `model` | Persisted first; falls back to start opt if unresolvable. `{:stop, :no_model}` if neither usable. |
| `system` | Start opt wins; falls back to persisted. |
| `opts` | Start opt wins; falls back to persisted. |
| `tools` | Start opt only — never persisted (function refs). |
| `title` | Persisted only — start opt `:title` is silently ignored on load. |
| `messages` | Derived from `Tree.messages(tree)`. `agent: [messages: _]` is silently ignored on load. |

Rationale: `model` has the strongest "this conversation was with X"
identity; other fields track the app's current config intent. `tree`
and `title` are artefacts of the conversation itself.

**Post-load seeding.** Before the Agent starts, Session seeds
`last_persisted_state` from the reconciled persistable subset. This is
what subsequent `:state`-event diffs compare against, so a `set_agent`
that happens to leave the persistable subset unchanged (e.g. a tools
update) correctly produces no write.

### 5.5 Persistence

Two categories with different triggers:

| Category | Mutator | Callback | Trigger |
|---|---|---|---|
| Tree (nodes + path + cursors) | Session | `save_tree` | Turn commits, navigation, branch initiation |
| State map (`model`, `system`, `opts`, `title`) | Agent + Session title | `save_state` | Agent `:state` events (change-detected), `set_title/2` |

**Change detection** for `save_state`: Session diffs the persistable
subset (`model`, `system`, `opts` sorted, `title`) against
`last_persisted_state` on every `:state` event. Unchanged → no write.
`opts` is canonicalised (sorted keyword) to avoid spurious saves on
reordered-but-equivalent inputs.

**Disjoint keys.** `save_tree` writes tree fields; `save_state` writes
state-map fields. Adapters that keep both in one backing store can
read-modify-write each side without conflict.

All store calls are **synchronous** and go through Session's mailbox
(no concurrent-write race for a single session). Session **never halts**
on store errors — success and failure both emit `:store` events.

**Write inventory:**

| Session op | save_tree | save_state |
|---|---|---|
| `start_link(new: _)` | no (first real mutation does it) | no |
| `start_link(load: _)` | no (read-only) | no |
| `prompt/2,3` at `:turn` | yes (with `new_node_ids`) | no |
| `cancel/1` | no | no |
| `resume/2` at `:turn` | yes | no |
| `navigate/2` | yes (empty `new_node_ids`) | no |
| `branch/2` (regen) | yes on nav, yes on `:turn` | no |
| `branch/3` (edit) | yes on nav, yes on `:turn` | no |
| `set_agent` (model/system/opts) | no | yes (via `:state` diff) |
| `set_agent` (tools/private) | no | no (not in persistable subset) |
| `set_title/2` | no | yes |
| `add_tool`/`remove_tool` | no | no (tools not persisted) |

### 5.6 Events

Every Agent event is re-tagged and forwarded verbatim to Session
subscribers:

```
{:agent, agent_pid, type, payload}
  →  {:session, session_pid, type, payload}
```

Session-specific events:

```
{:session, pid, :tree,  %{tree: Tree.t(), new_nodes: [node_id()]}}
{:session, pid, :title, String.t() | nil}
{:session, pid, :store, {:saved, :tree | :state}}
{:session, pid, :store, {:error, :tree | :state, reason}}
```

**Turn-commit ordering:**

```
prompt → forwarded streaming / :message / :step / :turn
       → :tree  %{tree, new_nodes}
       → :store {:saved, :tree}
```

`:turn` is what Session observes to trigger the commit; `:tree` fires
after the tree is mutated. Subscribers needing "logical turn boundary"
listen on `:turn`; those needing "tree structure changed" listen on
`:tree`.

### 5.7 Navigation and branching

All idle-only — returns `{:error, :not_idle}` when a turn is in flight.

**`navigate/2`.** Walks parent pointers from `node_id` back to root,
sets cursors for every parent → child pair along that path, resyncs
the Agent via `Agent.set_state(messages: _)`, and emits `:tree` with
empty `new_nodes`. `navigate(session, nil)` clears the active path
(subsequent prompt creates a new disjoint root) and does not touch
cursors or nodes.

**`branch/2,3` — a single primitive.** "Branch from X" always means X
is the parent of the new branch. The target's role determines the
legal arity:

| Call | Target role | Semantics |
|---|---|---|
| `branch(session, user_id)` | user | Regenerate this user's turn. Same content, new response. |
| `branch(session, assistant_id, content)` | assistant | Extend from this assistant with a new user `content` — "edit the next user message." |
| `branch(session, nil, content)` | — | New disjoint root. Atomic `navigate(nil) + prompt(content)`. |

Errors: `:not_user_node`, `:not_assistant_node`, `:not_found`,
`:not_idle`.

**Regen mechanics** (`branch/2`):

1. Validate target is a user node.
2. Tree path ends on the user; cursors along that path update to
   match.
3. Agent sees messages up to but **not** including the user (its
   parent path).
4. Session records `regen_source = user_id`.
5. `Agent.prompt(agent, content_of(user_id))`.
6. During the in-flight window, tree path and Agent messages are
   deliberately out of sync (tree ends on user, Agent ends on user's
   parent).
7. On the first `:turn` commit, drop the leading (duplicate) user
   from `response.messages` and push the rest as children of
   `user_id`. Clear `regen_source`.
8. Continuation segments push normally — the drop applies only to the
   first segment.
9. `:cancelled` / `:error` clears `regen_source` without tree
   mutation. Tree path remains on `user_id`; a subsequent call
   resyncs.

**Edit mechanics** (`branch/3` with assistant target):

1. Validate target is an assistant node.
2. Tree path and Agent messages both end on the assistant.
3. `Agent.prompt(agent, content)`.
4. On `:turn`, push all of `response.messages` as children of the
   assistant.

**Cursor updates.** After a branch turn commits, the cursor at the
divergence point points to the first newly-pushed child — the new
branch becomes the default on `extend/1`. Combined with `navigate/2`'s
full-path cursor update, this means the tree always remembers the
most-recent branch at every level: navigate to a node, later navigate
back to an ancestor + extend, and you land on the branch you last
visited.

### 5.8 Pub/sub, controllers, observers

Session maintains two sets:

- `subscribers` — everyone who receives events (superset).
- `controllers` — subset that holds the session alive when
  `idle_shutdown_after` is configured.

`subscribe/1,2,3` accepts `mode: :controller | :observer` (default
`:controller`). Subscription is idempotent per pid — calling again
with a different mode updates in place. `unsubscribe` releases
whichever mode was held. Monitors handle subscriber death.

Snapshot is built atomically in the subscribe `handle_call`:

```elixir
%Omni.Session.Snapshot{
  id:    String.t(),
  title: String.t() | nil,
  tree:  Tree.t(),
  agent: Omni.Agent.Snapshot.t()   # includes pending and partial
}
```

`snapshot.agent.state.messages` mirrors `Tree.messages(snapshot.tree)`
at the subscribe instant — treat the tree as source of truth for
committed structure; `agent.pending` / `agent.partial` carry the
streaming tail.

### 5.9 Idle shutdown

When `idle_shutdown_after` is a non-negative integer: if controller
count drops to zero **and** the Agent is `:idle`, Session schedules
`:idle_shutdown` after the configured ms. If either condition breaks
before it fires, the timer is cancelled.

**Evaluation triggers only on transitions** — never at init:

- Controller count goes to zero (unsubscribe, mode change
  `:controller → :observer`, controller death).
- Agent `:status :idle` event.

This gives the intuitive cross-case behaviour:

- Bare Session, no subscribers, no prompts → sits forever (no
  transitions occur).
- Bare Session with a controller that later unsubscribes → dies after
  the grace window.
- Manager-managed Session with auto-subscribed caller → dies when
  caller dies / unsubscribes.
- Session running a turn with no controllers → finishes the turn
  **before** shutdown fires; turn integrity preserved.

`idle_shutdown_after: 0` is valid — shutdown fires on the next
scheduler pass.

Standalone Session has no default (unset means never shut down). The
Manager layer injects its default (300_000 ms) into every session it
starts.

### 5.10 Public API

```elixir
# Lifecycle
Omni.Session.start_link(opts)
Omni.Session.stop(session)

# Turn control — passthrough to Agent
Omni.Session.prompt(session, content, opts \\ [])
Omni.Session.cancel(session)
Omni.Session.resume(session, decision)

# Navigation / branching (idle-only)
Omni.Session.navigate(session, node_id | nil)
Omni.Session.branch(session, user_node_id)
Omni.Session.branch(session, assistant_node_id | nil, content)

# Mutation
Omni.Session.set_agent(session, opts)            # → Agent.set_state/2
Omni.Session.set_agent(session, field, value_or_fun)
Omni.Session.set_title(session, title)
Omni.Session.add_tool(session, tool)             # over set_agent(:tools, _)
Omni.Session.remove_tool(session, tool_name)

# Inspection
Omni.Session.get_agent(session)                  # → Agent.get_state/1
Omni.Session.get_agent(session, key)
Omni.Session.get_tree(session)
Omni.Session.get_title(session)
Omni.Session.get_snapshot(session)

# Subscription
Omni.Session.subscribe(session, opts \\ [])      # mode: :controller | :observer
Omni.Session.subscribe(session, pid, opts \\ [])
Omni.Session.unsubscribe(session)
Omni.Session.unsubscribe(session, pid)
```

Session terminates the linked Agent as part of `stop/1` — it flips
`:trap_exit` during termination specifically so the linked Agent's
exit doesn't race `GenServer.stop`.

---

## 6. Store

`Omni.Session.Store` is a single module containing both the adapter
**behaviour** and the **dispatch functions**.

### 6.1 Canonical shape

A store is a `{module, keyword()}` tuple — adapter + config. This is
the shape everywhere: `Session.start_link(store: _)`, dispatch calls,
and application-owned wrapper modules.

```elixir
store = {Omni.Session.Store.FileSystem, base_path: "/data/sessions"}
Omni.Session.Store.delete(store, "abc")
```

No global `Application.env` fallback — apps wrap the tuple in their
own helper (`MyApp.Storage.store()`) if they want centralised config.

### 6.2 Behaviour

```elixir
@callback save_tree(cfg, session_id, Tree.t(), keyword()) :: :ok | {:error, term()}
@callback save_state(cfg, session_id, state_map(), keyword()) :: :ok | {:error, term()}
@callback load(cfg, session_id, keyword()) ::
            {:ok, Tree.t(), state_map()} | {:error, :not_found}
@callback list(cfg, keyword()) :: {:ok, [session_info()]}
@callback delete(cfg, session_id, keyword()) :: :ok | {:error, term()}
@callback exists?(cfg, session_id) :: boolean()
```

**`state_map`** is a strict four-key shape (partial on load, full on
write):

```elixir
%{
  model:  Omni.Model.ref(),      # {:anthropic, "claude-sonnet-4-5"}
  system: String.t() | nil,
  opts:   keyword(),             # canonicalised (sorted)
  title:  String.t() | nil
}
```

`save_state` always receives the full subset Session intends to retain
— overwrite semantics, no partial-merge at the behaviour level.

**`list/2` must honour `:limit` and `:offset`**. Ordering is
`updated_at` descending. Other opts are adapter-specific.

**`exists?/2`** is a non-racy presence check (returns false on adapter
errors). Used by Session to reject `new: binary_id` collisions with
`{:error, :already_exists}`. It is **not** atomic with the subsequent
write — a race between two concurrent `start_link(new: "x")` calls is
documented as a known edge case (both could pass the check and race
on the write). Fully resolving this requires an adapter-level
`create_if_absent` or Manager-level dedup (partially addressed by
Manager's Registry).

**Errors** from `save_tree` / `save_state` / `delete` are
adapter-specific. POSIX atoms (`:enoent`, `:eacces`) from filesystem
adapters bubble up unwrapped.

### 6.3 FileSystem reference adapter

Per-session directory, two files:

```
<base_path>/<session_id>/
  nodes.jsonl     # one JSON-encoded node per line
  session.json    # path, cursors, state-map fields, timestamps
```

- `nodes.jsonl` behaviour depends on the `:new_node_ids` opt:
  - **absent (nil)** — full rewrite from the tree's node set.
  - **non-empty list** — append just those nodes (`:append, :sync`).
  - **empty list** — no-op (used by navigation-only saves that
    change `path`/`cursors` but add no nodes).

  Messages and usage go through `Omni.Codec.encode/1`. Malformed
  lines (e.g. a torn trailing write after a crash) are skipped with
  a logger warning — one bad line doesn't brick the session.
- `session.json` is a single merged file. `save_tree` and `save_state`
  write disjoint keys — merge is read-modify-write. Writes use
  POSIX atomic tmp-file + rename for crash safety: a crash mid-write
  leaves either the old file intact or the new one fully on disk,
  never a truncated file.
- `model` is encoded as plain JSON `[provider_string, model_id]` for
  inspectability, decoded via `String.to_existing_atom/1` (so a
  rogue provider string can't create a new atom). `opts` uses
  `Omni.Codec.encode_term/1` (ETF-wrapped for fidelity of atom keys
  and arbitrary values). `created_at` / `updated_at` are ISO8601
  strings managed by the adapter.

Configuration: `base_path` required; adapter raises `ArgumentError`
when absent.

Load corner cases:

- `session.json` missing → `{:error, :not_found}`.
- `session.json` present, `nodes.jsonl` missing → `{:ok, %Tree{},
  state_map}` (valid early state — e.g. `set_title` before first
  prompt).
- Partial `state_map` keys returned as-is; Session's load-mode
  resolution merges against start opts.

Adapters for SQLite, Postgres, Redis, etc. are out of scope for the
initial release — the behaviour is documented clearly enough that a
third party can implement one from the spec alone.

---

## 7. Manager

`Omni.Session.Manager` is a `use`-pattern Supervisor supervising a
Registry, a DynamicSupervisor, and a Tracker. It handles multi-session
lifetimes, id-keyed lookup, store injection, and cross-session status.

### 7.1 The `use` pattern

```elixir
defmodule MyApp.Sessions do
  use Omni.Session.Manager
end

# application.ex
children = [
  {MyApp.Sessions,
     store: {Omni.Session.Store.FileSystem, base_path: "priv/sessions"}}
]
```

`use` generates `child_spec/1`, `start_link/1`, and shorthand
delegates (`create/1`, `open/2`, `close/1`, `delete/1`, `whereis/1`,
`list/1`, `list_running/0`, `subscribe/0`, `unsubscribe/0`).

Apps wanting multiple Managers (multi-tenant isolation, per-workspace)
define multiple modules. No single global "default" Manager.

The `Omni.Session.Manager.*` functions are public — tests and advanced
code may call them with an explicit module atom.

### 7.2 Supervision

`:rest_for_one` with children in `[Registry, DynamicSupervisor,
Tracker]` order:

- **Tracker crash** (most likely — biggest state): only Tracker
  restarts. Running sessions are preserved. Tracker rebuilds by
  enumerating the Registry.
- **DynamicSupervisor crash** (rare, severe): DynSup and Tracker
  restart. All sessions die with the DynSup; Registry auto-clears via
  its DOWN monitors; Tracker rebuilds against an empty Registry.
- **Registry crash** (rare, catastrophic): all three restart.
  `:rest_for_one` avoids leaving running sessions registered to a dead
  Registry instance — the only failure mode where cascading is the
  correct behaviour.

Children are `:temporary` under the DynamicSupervisor — sessions do
not auto-restart on crash.

Config lives in `:persistent_term` keyed by the Manager module, set
once in `Supervisor.init/1`. Under `:rest_for_one`, child crashes do
not re-run the Supervisor's init, so the config persists across
child-level restarts — Tracker and Registry can come and go without
losing their view of `:store` / `:idle_shutdown_after`.

### 7.3 Configuration

```elixir
{MyApp.Sessions,
   store: {...},                         # required
   idle_shutdown_after: 300_000}          # default
```

- `:store` (required) — `{module, keyword()}`, injected into every
  session start.
- `:idle_shutdown_after` — `non_neg_integer() | nil`, default
  `300_000`. Passes through to each session; caller can override
  per-call. Pass `nil` to disable manager-wide.
- `:name` — overrides the registered name; defaults to the `use`-ing
  module.

No `agent_defaults` or other default-start-opts mechanism — apps wrap
their `create/1` in helper functions on their own module.

### 7.4 Public API

```elixir
# Lifecycle
Manager.create(manager, opts \\ [])   :: {:ok, pid}
                                       | {:error, :already_exists}
                                       | {:error, {:invalid_opt, atom}}
                                       | {:error, term}
Manager.open(manager, id, opts \\ []) :: {:ok, :started | :existing, pid}
                                       | {:error, :not_found}
                                       | {:error, {:invalid_opt, atom}}
                                       | {:error, term}
Manager.close(manager, id)            :: :ok                   # idempotent
Manager.delete(manager, id)           :: :ok | {:error, term}  # stop then Store.delete

# Discovery
Manager.whereis(manager, id)          :: pid | nil             # Registry lookup
Manager.list(manager, opts \\ [])     :: {:ok, [session_info]}  # → Store.list
Manager.list_running(manager)         :: [entry]                # → Tracker

# Cross-session pub/sub
Manager.subscribe(manager)            :: {:ok, [entry]}
Manager.unsubscribe(manager)          :: :ok
```

where `entry :: %{id, title, status, pid}`.

**`create`** generates an id (or uses `:id`), starts the Session under
the DynamicSupervisor with `new:` injected, auto-subscribes the
caller as `:controller` (opt out: `subscribe: false`), and synchronously
calls `Tracker.add/3` before returning.

**`open`** returns a three-tuple. `:started` means the session wasn't
running and the Manager loaded it — start-time opts were applied.
`:existing` means the session was already up — start-time opts
(`:agent`, `:title`, `:idle_shutdown_after`, `:subscribers`) are
**silently dropped**, but `:subscribe` is honoured (it's a
subscription, not a state mutation). Callers needing fresh config
`close` + `open`.

**Manager-owned opts** (`:store`, `:name`, `:new`, `:load`) passed to
`create`/`open` return `{:error, {:invalid_opt, key}}`.

**Caller auto-subscribe mechanics.** The DynamicSupervisor is what
actually calls `Session.start_link`, so Session's own `subscribe:
true` sugar (which uses `hd(callers)`) would subscribe the
DynamicSupervisor and permanently pin every session against
idle-shutdown. Manager strips `:subscribe` from caller opts and
explicitly injects `subscribers: [caller]` instead. On the `:existing`
branch of `open`, Manager calls `Session.subscribe(pid, caller, mode:
:controller)` **before** `Tracker.add` — closes the timer race and
the transient no-controller window visible to Manager-level
subscribers.

### 7.5 Tracker

`Omni.Session.Manager.Tracker` is an internal GenServer (`@moduledoc
false`) that:

1. Observes every running session as `:observer` (lifetime-neutral —
   does not pin any session open).
2. Maintains `%{id => %{id, title, status, pid}}`.
3. Fans out `:session_added` / `:session_status` / `:session_title` /
   `:session_removed` to Manager-level subscribers.

**Hand-off.** `Manager.create/open` calls `Tracker.add(id, pid)`
synchronously before returning the pid. Every pid a caller sees is
already tracked. On the `:existing` branch, `add` is idempotent —
no duplicate `:session_added`.

**Recovery.** On Tracker crash and supervised restart, the new Tracker
enumerates the Manager's Registry and re-observes each running session
silently (no `:session_added` for rebuilds). Manager-level subscribers
die with the old Tracker pid and must re-subscribe — documented as
accepted behaviour.

### 7.6 Manager-level events

```
{:manager, manager_module, :session_added,   %{id, title, status, pid}}
{:manager, manager_module, :session_status,  %{id, status}}
{:manager, manager_module, :session_title,   %{id, title}}
{:manager, manager_module, :session_removed, %{id}}
```

The second element is the Manager module atom (not the Tracker pid) —
what the caller already holds, pattern-matchable at compile time, and
it naturally distinguishes events across multiple Managers.

- `:session_added` fires after `Tracker.add` returns. Suppressed on
  `open :existing` (no state change).
- `:session_status` / `:session_title` forward underlying Session
  transitions.
- `:session_removed` fires on DOWN regardless of cause (close, delete,
  crash, idle-shutdown).

No cross-session ordering guarantees — events from different sessions
may interleave arbitrarily.

### 7.7 Opt flow for a managed session

When `Manager.create` or `open` builds the final `Session.start_link`
opts:

1. Reject Manager-owned opts (`:store`, `:name`, `:new`, `:load`).
2. Inject Manager config: `:store`, `:idle_shutdown_after` (falling
   back to 300_000 default).
3. Pass through caller opts (`:agent`, `:title`, `:subscribers`, per-
   call `:idle_shutdown_after`).
4. Inject `:new` / `:load` based on which API was called.
5. Inject `subscribers: [caller]` when `subscribe: true` (default).
6. Inject `:name` as `{:via, Registry, {reg, id}}`.

---

## 8. Module layout

```
lib/omni/
├── agent.ex                       # public: behaviour, use macro, API
├── agent/
│   ├── state.ex                   # public %State{} + validate_messages
│   ├── snapshot.ex                # public %Snapshot{}
│   ├── server.ex                  # internal GenServer  (@moduledoc false)
│   ├── step.ex                    # linked Task: stream one LLM request
│   └── executor.ex                # linked Task: parallel tool execution
├── session.ex                     # public: Session GenServer + API
├── session/
│   ├── snapshot.ex                # public %Snapshot{}
│   ├── tree.ex                    # pure-data branching tree
│   ├── store.ex                   # adapter behaviour + dispatch
│   ├── store/
│   │   └── file_system.ex         # reference FileSystem adapter
│   ├── manager.ex                 # Supervisor + use macro + API
│   └── manager/
│       └── tracker.ex             # internal Tracker  (@moduledoc false)
```

Public modules have `@moduledoc` + public `@typedoc` / `@doc` /
`@spec`. Internal modules (`Agent.Server`, `Agent.Step`,
`Agent.Executor`, `Manager.Tracker`) carry `@moduledoc false`.

---

## 9. Testing

Tests live under `test/omni/agent/**` and `test/omni/session/**` and
exercise the full lifecycle through public APIs. Shared helpers:

- `test/support/agent_case.ex` — stubs fixtures via `Req.Test`, starts
  agents, collects events.
- `test/support/session_case.ex` — same shape for sessions.
- `test/support/test_agents.ex` — canned callback modules covering
  each callback path.
- `test/support/failing_store.ex` — drop-in store that returns errors
  on demand.

**Fixtures** are real Anthropic SSE recordings copied from the `omni`
package — `anthropic_text.sse`, `anthropic_tool_use.sse`,
`anthropic_thinking.sse`. Compose via `stub_fixture` (single response)
and `stub_sequence` (ordered responses for multi-step scenarios).

No tests hit a real API. `test/support/` is compiled in `:test` via
`elixirc_paths`.

---

## 10. Known limitations and parked work

Deliberately out of scope; all tracked in `context/roadmap.md`:

- **Concurrent duplicate-id race on `new:`.** `Store.exists?` + write
  is not atomic. Two concurrent `start_link(new: "x")` calls can both
  pass the check and race. Under a Manager, the Registry catches most
  of this; fully resolving requires an adapter-level
  `create_if_absent`.
- **`:data` field on Agent state** — app-defined per-session metadata.
  Agent, not Session, to benefit plain-Agent users too. Deferred until
  a concrete consumer surfaces.
- **Title auto-generation helpers** — sugar over the
  subscribe-and-set pattern.
- **Store retry / write-behind queue** for high-latency adapters.
- **Persistent event log / replay** across process restarts.
- **Distributed Manager** — cross-node Registry and Tracker.
- **Manager telemetry** at operation boundaries.
- **Per-session Tracker metadata** — app-attachable fields on the
  Tracker's session map for richer sidebar UIs.

These remain deferred until concrete demand arrives.
