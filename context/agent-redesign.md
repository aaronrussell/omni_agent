# Agent Redesign

## Purpose

This document specifies a refactor of `Omni.Agent`. It captures design
decisions reached during a round of rethinking the package's direction after
a previous branch overextended the Agent with persistence, durability, and
tree-navigation concerns.

The refactor is motivated by a layered split: **`Omni.Agent` is the turn
engine, and a separate (future) `Omni.Session` process will be the
conversation lifetime**. Everything durable, persistent, branched, or
multi-consumer belongs to Session. This document covers the Agent half and
keeps the Session story brief — Session will be designed in a separate
document once Agent is stable.

## Broader vision (summary)

Two processes, two temporal scopes:

- **`Omni.Agent`** — ephemeral, single-turn-focused. Owns a model, a context
  (system prompt, messages, tools), user-defined private state, and an event
  stream. Has no identity beyond a pid, no persistence, no message tree.
  Source of truth for *in-flight* state during a turn.
- **`Omni.Session`** (future, not in scope here) — longer-lived wrapper.
  Owns identity, persistent storage, a branching message tree, its own
  pub/sub for application subscribers, and the ability to navigate and
  regenerate. Starts, subscribes to, and drives an inner Agent for each
  active turn. Source of truth for *at-rest* conversation state between
  turns.

The handoff between these scopes happens at `:turn` events — the Agent's
in-flight pending messages get committed, and the Session captures them
into its tree.

## Scope of this document

Covered:

- The Agent's state shape, lifecycle, events, pub/sub, public API, callbacks,
  and validation rules after the refactor.

Not covered:

- Session design, persistence adapters, tree schema, branching/navigation
  semantics, snapshot-on-join consistency for Session subscribers.
- Migration path from the current implementation.

## Goals

- Keep the Agent's core simple and well-scoped — ideally not much bigger than
  today's `Omni.Agent.Server`.
- Make the Agent composable with a future Session wrapper using only its
  public API (no reaching into internals).
- Adopt pub/sub as the native event delivery mechanism, so observability,
  metrics, and multiple consumers work without a separate multiplexer.
- Keep commit semantics crisp: `state.messages` always reflects a valid
  committed history.

---

## Agent responsibilities

In scope:

- Run a turn: given a model, context, and a prompt, drive LLM requests
  through to a natural stopping point.
- Manage the decision/execution flow for tool use.
- Emit streaming and lifecycle events to subscribers.
- Expose committed state and in-flight snapshot on demand.

Out of scope (belongs in Session):

- Identity, naming, session IDs.
- Persistence to storage.
- Branching, message trees, navigation.
- Crash recovery across process restarts.
- Multi-consumer event distribution beyond simple pub/sub at Agent level.

---

## State shape

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

Changes from current implementation:

- **Flattened.** `%Context{}` is no longer nested inside state. `system`,
  `messages`, and `tools` are top-level fields. The Agent rebuilds a
  `%Context{}` on each call to `Omni.stream_text/3` internally.
- **`:meta` removed.** Not needed in the layered model — external metadata
  (titles, tags, etc.) is Session's responsibility. Plain-Agent users that
  want an app stash use `:private`.
- **`:private` is settable at `start_link`.** Previously only settable by
  callback modules via `init/1`'s return. Now also populatable via a
  `:private` start option for the no-callback-module case.
- **`state.messages` is committed-only.** It only changes at `:turn` events
  (which commit in-flight pending messages) or explicit `set_state(:messages,
  ...)` mutations. Never updated mid-stream.

### Access semantics

- `state.private` is readable externally (via `get_state`), but **not**
  writable via `set_state`. Callback modules own mutation.
- All other state fields are readable and writable via `set_state` when the
  agent is idle.
- Server-level configuration (`:tool_timeout`, `:subscribe`, GenServer opts)
  lives on the internal server struct, not in `%State{}`.

---

## Turn lifecycle

The lifecycle operates at two levels:

- **Step** — one LLM request-response cycle. A turn may contain many.
- **Turn** — starts with `prompt/2,3`. Ends when `handle_turn/2` returns
  `{:stop, state}` (or when cancelled/errored).

A turn may also be *continued* within itself: `handle_turn/2` returning
`{:continue, content, state}` commits the current segment, appends a new
user message, and loops. There is no practical cap on continuations; each
segment is a genuine valid stopping point.

### Commit semantics

During a turn, new messages accumulate in internal `pending_messages`. They
do not enter `state.messages` until committed.

Commit happens on **every** `:turn` event, regardless of whether the variant
is `{:stop, ...}` or `{:continue, ...}`. Both are valid stopping points —
the model produced a complete response with a natural stop reason.

- `:turn {:stop, response}` — commit pending, agent transitions to `:idle`.
- `:turn {:continue, response}` — commit pending, new user message appended
  to pending, agent continues.
- `:cancelled` — pending discarded, agent transitions to `:idle`,
  `state.messages` unchanged.
- `:error` — pending discarded, agent transitions to `:idle`,
  `state.messages` unchanged.

**Invariant** (see Validation below): `state.messages` is empty, or ends
with a message whose role is `:assistant` and which contains no `ToolUse`
blocks. This invariant is maintained automatically by turn lifecycle and
enforced at `set_state` boundaries.

---

## Events

The Agent is pub/sub. All events are delivered as `{:agent, pid, type,
payload}` messages to subscribed pids via `send/2`.

### Streaming events

Forwarded from each LLM response as chunks arrive:

```
{:agent, pid, :text_start,     %{index: 0}}
{:agent, pid, :text_delta,     %{index: 0, delta: "..."}}
{:agent, pid, :text_end,       %{index: 0, content: %Text{}}}
{:agent, pid, :thinking_start, %{index: 0}}
{:agent, pid, :thinking_delta, %{index: 0, delta: "..."}}
{:agent, pid, :thinking_end,   %{index: 0, content: %Thinking{}}}
{:agent, pid, :tool_use_start, %{index: 1, id: "call_1", name: "search"}}
{:agent, pid, :tool_use_delta, %{index: 1, delta: "..."}}
{:agent, pid, :tool_use_end,   %{index: 1, content: %ToolUse{}}}
```

### Lifecycle events

```
{:agent, pid, :message,     %Message{}}                      # a message was appended to pending
{:agent, pid, :step,        %Response{}}                     # one request-response cycle completed
{:agent, pid, :turn,        {:stop, %Response{}}}            # turn ended, pending committed, now idle
{:agent, pid, :turn,        {:continue, %Response{}}}        # turn segment committed, turn continues
{:agent, pid, :tool_result, %ToolResult{}}                   # a single tool result
{:agent, pid, :pause,       {reason, %ToolUse{}}}            # handle_tool_use paused
{:agent, pid, :retry,       reason}                          # handle_error returned :retry
{:agent, pid, :cancelled,   %Response{stop_reason: :cancelled}} # cancel/1 invoked; pending discarded
{:agent, pid, :error,       reason}                          # terminal error; pending discarded
{:agent, pid, :state,       %State{}}                        # set_state mutation applied
```

### Event ordering

Within a step:

```
prompt(agent, "hi")
  → :message (user)                         # user msg appended to pending
  → :text_start / :text_delta* / :text_end  # streaming deltas
  → :message (assistant)                    # assistant msg appended to pending
  → :step  %Response{}                      # cycle complete
```

If tools are used in that step:

```
  → :text_*  and/or :thinking_*  and :tool_use_*  streaming events
  → :message (assistant with tool_use blocks)
  → :step
  → :tool_result (one per executed/rejected/provided result)
  → :message (user-role message containing all ToolResult blocks)
  → [next step starts: :text_*, :message, :step, ...]
```

At turn boundary:

```
  → :turn {:stop, response}          # or {:continue, response}, then loops
```

### Payload notes

- `:message` carries the finalized `%Message{}`. It fires *after* all
  streaming delta events for that message, and *before* `:step`.
- `:step.response.messages` contains the messages that were added in this
  step (at minimum the assistant response; for non-first steps also the
  preceding tool-result user message).
- `:turn.response.messages` contains the messages committed in this segment
  (i.e. everything in pending at commit time). For a turn with continuations,
  each `:turn` event's response carries only that segment's messages, not
  the whole turn's.
- `:tool_result` fires per-result, before the aggregated user `:message`
  event for the tool-result message. This preserves per-tool granularity for
  UIs that want it while keeping `:message` strictly one-per-message.
- `:state` fires after a successful `set_state/2,3`. Payload is the full new
  `%State{}`. Subscribers should treat it as "throw away your cached view,
  here's the new one." Not fired on turn commits (that's `:turn`).

---

## Snapshot

A consistent view of the Agent at an instant in time:

```elixir
%Omni.Agent.Snapshot{
  state:   %State{},           # full public state (committed messages)
  pending: [Message.t()],      # messages accumulated this turn, not yet committed
  partial: %Message{} | nil    # currently-streaming message, or nil if not streaming
}
```

Consumers who want "everything known right now" compose it as
`state.messages ++ pending ++ List.wrap(partial)`.

Exposed via:

- `Agent.get_snapshot(agent)` — synchronous call, returns `%Snapshot{}`.
- `Agent.subscribe(agent)` — subscribes caller and returns `{:ok,
  %Snapshot{}}` atomically, so new subscribers can populate their view and
  immediately begin consuming live events without gaps.

### Late-join consistency

The Agent guarantees that a subscriber joining mid-stream sees a consistent
view: the returned `%Snapshot{}` captures state at the instant of
subscription, and every event emitted after that point is delivered to the
new subscriber. Because `subscribe/1,2` is a `GenServer.call` handled
atomically — snapshot built, pid added to subscribers, reply sent, all
within one `handle_call` clause — there is no window in which an event can
fire between the snapshot being taken and the subscriber being registered.

This guarantee does not extend to consumer-side pacing: a slow subscriber
may fall behind on its own mailbox, but that is the consumer's problem, not
a gap in delivery.

What the Agent cannot provide — and what Session will — is a view that
spans multiple Agent lifetimes (e.g., a conversation whose committed
history predates this Agent process), replay of historical events from a
persistent log, or resume-from-sequence semantics after a subscriber
disconnect. Those are qualitatively different capabilities, not stronger
versions of the same guarantee.

---

## Pub/sub

Replaces the current single-`listener` mechanism. The Agent maintains a
`MapSet` of subscribed pids (plus monitors for cleanup on subscriber death).

### API

- `Agent.subscribe(agent) :: {:ok, Snapshot.t()}` — subscribes caller.
- `Agent.subscribe(agent, pid) :: {:ok, Snapshot.t()}` — subscribes given pid.
- `Agent.unsubscribe(agent) :: :ok` — removes caller.
- `Agent.unsubscribe(agent, pid) :: :ok` — removes given pid.

### Semantics

- Subscribing is idempotent.
- A subscriber receives all events emitted after subscription.
- Subscribers that die are removed automatically (via monitor).
- Subscription does not gate who can call the control API (`prompt`,
  `cancel`, etc.). Any process with the pid may control; only subscribers
  receive events.

### Start-time convenience

To avoid a mandatory two-step `start_link` + `subscribe` in simple cases:

```elixir
Omni.Agent.start_link(model: ..., subscribe: true)              # subscribes caller
Omni.Agent.start_link(model: ..., subscribers: [pid1, pid2])     # subscribes given pids
```

`:subscribe` and `:subscribers` may be combined. No auto-subscribe behaviour
beyond these explicit options — `prompt/2,3` does not implicitly subscribe
the caller.

---

## Public API

### Lifecycle

- `start_link(opts)` and `start_link(module, opts)` — start an agent,
  optionally with a callback module. Links to caller.

### Turn control

- `prompt(agent, content)` / `prompt(agent, content, opts)` — start a turn.
  Appends a user message with the given content and begins generation. Idle
  only starts a new turn; running/paused stages the content for the next
  turn boundary (existing steering behaviour preserved). `content` may be a
  string or a list of content blocks.
- `cancel(agent)` — cancel the current turn. Discards pending, emits
  `:cancelled`, returns agent to `:idle`. `{:error, :idle}` if already idle.
- `resume(agent, decision)` — resume from a `:pause`. Existing semantics:
  `:execute | {:reject, reason} | {:result, result}`.

There is intentionally **no** `regenerate/1` or `prompt/1` (no-content)
function. The invariant that `state.messages` ends with an assistant message
means there is no legitimate state from which to "run from current
messages" without new content. Regeneration is expressed as `set_state` +
`prompt` with the desired user content. (See Session Regeneration Pattern
below.)

### Inspection

- `get_state(agent)` — returns `%State{}`.
- `get_state(agent, key)` — returns a single field.
- `get_snapshot(agent)` — returns `%Snapshot{}`.

### Mutation (idle only)

- `set_state(agent, opts)` — replace multiple fields atomically. Accepts
  keys `:model`, `:system`, `:messages`, `:tools`, `:opts`. Does not accept
  `:private` or `:status`/`:step`/`:meta`.
- `set_state(agent, field, value_or_fun)` — replace or transform a single
  field. Same allowed keys.

### Subscription

- `subscribe/1,2`, `unsubscribe/1,2` — see Pub/sub above.

### Return codes

- `set_state` and other idle-only operations return `{:error, :running}` if
  not idle, `{:error, {:invalid_key, key}}` for bad keys, `{:error,
  :invalid_messages}` if the messages invariant would be violated (see
  Validation), and `{:error, {:model_not_found, ref}}` for unresolved models.

---

## Validation

### `set_state(:messages, list)` invariant

The `list` must satisfy one of:

- `list == []`, or
- The last message has `role: :assistant` and contains no `%ToolUse{}`
  content blocks.

This corresponds semantically to "the prior turn ended with a natural
`:stop` — no unresolved tool calls, not a dangling user message." It is the
sole condition under which the Agent can sit idle in a state from which a
future `prompt/2,3` is guaranteed to be LLM-safe.

Violations return `{:error, :invalid_messages}`. No deep list validation —
only the terminal message is checked. Malformed interior (e.g., two
consecutive user messages mid-list) is the caller's responsibility.

### Why this rule

- User-role terminal messages would cause the next LLM request to fail
  (LLMs reject consecutive user messages).
- Assistant messages with unresolved `ToolUse` blocks would cause the next
  LLM request to fail (tool results expected).
- Under normal turn flow this invariant holds automatically, because pending
  is only committed when the model's stop reason is a natural stop and no
  dangling tool-use situation persists.

### Implication: Session regeneration pattern

With no `regenerate/1` primitive, Session regenerates by reconstructing the
active path up to the assistant-free position and then prompting with the
original user content:

```elixir
# Regenerate the assistant response at some tree node.
def regenerate_at(session, user_node_id) do
  parent_path  = walk_to_parent(session.tree, user_node_id)  # ends with assistant or empty
  user_content = get_node(session.tree, user_node_id).content

  :ok = Omni.Agent.set_state(session.agent, messages: parent_path)
  :ok = Omni.Agent.prompt(session.agent, user_content)
end
```

Two explicit steps, no magic, no new Agent primitives.

---

## Callbacks

### Changes

```elixir
@callback init(state :: State.t()) :: {:ok, State.t()} | {:error, term()}
```

The callback receives the fully-resolved initial state (start options
merged, model resolved) and returns a possibly-modified state. The callback
can tweak any field — inject `private`, preload messages, swap the system
prompt, add tools. The returned state is validated before the server
transitions to `:idle` (same rule as `set_state(:messages, ...)`).

Differences from today:

- Receives `%State{}`, not raw opts. Server-level options (`:name`,
  `:tool_timeout`, `:subscribe`, etc.) are not visible to `init`.
- Returns the full state, not just `private`.
- An invalid returned state (violating the messages invariant) causes
  `start_link` to fail with `{:error, :invalid_messages}`.

### Unchanged

```elixir
@callback handle_turn(response :: Response.t(), state :: State.t()) ::
            {:stop, State.t()} | {:continue, term(), State.t()}

@callback handle_tool_use(tool_use :: ToolUse.t(), state :: State.t()) ::
            {:execute, State.t()}
            | {:reject, term(), State.t()}
            | {:result, ToolResult.t(), State.t()}
            | {:pause, term(), State.t()}

@callback handle_tool_result(result :: ToolResult.t(), state :: State.t()) ::
            {:ok, ToolResult.t(), State.t()}

@callback handle_error(error :: term(), state :: State.t()) ::
            {:stop, State.t()} | {:retry, State.t()}

@callback terminate(reason :: term(), state :: State.t()) :: term()
```

All remain optional with sensible defaults via `defoverridable`.

---

## Start options

```
:model         (required) — {provider_id, model_id} or %Model{}
:system                    — system prompt string
:messages                  — initial messages (subject to validation)
:tools                     — list of %Tool{} structs
:opts                      — inference opts passed to stream_text each step
:private                   — initial private map for callback-less use
:subscribe                 — boolean; if true, subscribes caller
:subscribers               — list of pids to subscribe
:tool_timeout              — per-tool execution timeout (ms), default 5_000
:name, :timeout, :hibernate_after, :spawn_opt, :debug  — standard GenServer options
```

Differences from today:

- `:context` option removed (flattened into `:system`, `:messages`,
  `:tools`).
- `:listener` option replaced by `:subscribe` / `:subscribers`.
- `:meta` option removed.
- `:private` option added.

---

## Parked / future work

The following are out of scope for this refactor but have been considered:

- **`init/1` triggering an initial prompt.** The funky use case of "init
  preloads messages and agent starts responding immediately." Deferred. A
  likely future shape is an extended init return: `{:ok, state, {:prompt,
  content, opts}}`, which the server handles by synthesizing a `prompt/2,3`
  call after init completes. Left for a follow-up once the core refactor
  lands.
- **`:prompt` start option** (e.g., `start_link(prompt: "Hello")`). Related
  to the above; parked for the same reason.

---

## What Session will add (forward-looking summary)

This is a preview only — Session is designed in a separate document.

- Identity (session id) and registry lookup.
- Persistent storage via an adapter protocol.
- A branching message tree; the Agent's `state.messages` is the current
  active path materialized from the tree.
- Session-level pub/sub for application subscribers (distinct from Agent
  pub/sub; Session forwards + augments Agent events).
- `:node` and `:tree` events for tree mutations and active path changes.
- Navigation, branching, and regeneration APIs built on top of
  `Agent.set_state` + `Agent.prompt`.
- Late-join snapshot consistency for Session subscribers, composed from the
  Session tree plus `Agent.get_snapshot` for the in-flight partial.

Session uses only the Agent's public API. No Agent internals are exposed
upward.
