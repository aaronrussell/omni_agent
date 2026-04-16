# Durable Agents

**Status:** Phases 1 and 2 complete; Phases 3–4 planned
**Supersedes:** `context/session.md` (Session-wrapper design, superseded)
**Direction:** `Omni.Agent` absorbs durability / persistence / tree concerns directly — no separate `Omni.Session` process.

---

## Summary

Extend `Omni.Agent` so it is:

- **Durable** — can be left running in the background; late subscribers catch up via snapshot without missing streaming chunks
- **Multi-subscriber** — multiple processes can observe one agent
- **Navigable** — conversation is a branching tree (flat list is the degenerate case)
- **Optionally persistent** — pluggable store saves the tree and agent config; no-op by default
- **Registry-backed** — supervised agents are findable by id

Consumers who don't need durability/persistence/branching pay nothing.

---

## Why not a Session wrapper (rationale)

The earlier plan was an `Omni.Session` GenServer wrapping `Omni.Agent`. Session would hold the tree, forward every agent event with a pid rewrite, sync its tree back into `agent.context.messages` before every prompt, and own persistence + subscribers.

Every one of those responsibilities is a function of *who owns the conversation state*. That's the agent. Wrapping with a session moves the source of truth *above* the agent rather than into it, and all the machinery to keep the two in sync is pure overhead — it exists only because there are two stateful processes instead of one.

The unified design:

- Removes event forwarding (one process emits events directly)
- Removes tree-to-context syncing (the agent derives messages from its own tree)
- Removes the two-representation problem (tree is the internal model; flat messages are derived via `Tree.messages/1`)

Every capability from the session plan still lands. It just lands on the right module.

---

## State layout

```elixir
%Omni.Agent.State{
  id:      String.t() | nil,      # nil for ephemeral agents; populated only when a store is configured
  model:   Model.t(),
  system:  String.t() | nil,
  tools:   [Tool.t()],
  tree:    Omni.Agent.Tree.t(),   # replaces context.messages
  opts:    keyword(),             # inference options passed to stream_text
  meta:    map(),                 # arbitrary user data; title lives here
  private: map(),                 # runtime-only, not persisted, callback-mutable
  status:  :idle | :running | :paused,
  step:    non_neg_integer()
}
```

Changes from current:

- `:id` — new; `nil` for ephemeral agents, populated only when a store is configured (id generation is a Store callback, see "Store" below)
- `:system`, `:tools` — decomposed out of the old `:context` field
- `:tree` — replaces `context.messages`
- `:context` (as a user-facing field) — removed; `%Omni.Context{}` is still built on the fly internally when calling `stream_text`
- `:meta` — **kept** (previously planned for removal; no longer necessary since no Session layer). Titles and app-specific data live here.

Internally the server tracks additional non-user-facing state:

- `subscribers` — `MapSet.t(pid)` of monitored pids
- `partial_message` — `[content_block] | nil` — in-flight assistant message during streaming
- `turn_start_node_id` — tree cursor at turn start; dual-purpose for cancel/error rewind and for building per-turn responses
- `store` — store adapter reference (optional)
- existing turn-lifecycle state: `pending_usage`, `prompt_opts`, `next_prompt`, `last_response`, tool-decision fields, etc.

`pending_messages` (current internal list) is removed — tree commits per-message.

---

## Public API

### Starting / loading

Persistence mode is explicit at start time via `:store` plus at most one of `:new` / `:load`. There is no global store config — every persisted agent is configured at start.

```elixir
# Ephemeral (no persistence, no id)
{:ok, pid} = Omni.Agent.start_link(model: m)

# New persisted agent, auto-generated id (via Store callback)
{:ok, pid} = Omni.Agent.start_link(model: m, store: Store.FileSystem)

# New persisted agent with explicit id — errors if "x" already exists
{:ok, pid} = Omni.Agent.start_link(model: m, store: Store.FileSystem, new: "x")

# Load existing agent — errors if "x" does not exist
{:ok, pid} = Omni.Agent.start_link(store: Store.FileSystem, load: "x")
```

`Omni.Agent.Supervisor.start_agent/1,2` accepts the same opts and adds registration + idle timeout:

```elixir
{:ok, pid} = Omni.Agent.Supervisor.start_agent(module \\ nil, opts)
```

|                | `start_link`              | `Supervisor.start_agent`        |
|----------------|---------------------------|---------------------------------|
| Linkage        | Caller                    | `Omni.Agent.Supervisor`         |
| Registry       | Not registered            | Registered under `:id`          |
| Idle timeout   | No                        | Yes (configurable)              |
| Typical use    | Tests, scripts, embedding | Durable sessions                |

`Omni.Agent.Supervisor` and `Omni.Agent.Registry` are auto-started via `omni_agent`'s Application module — no setup required in the consumer's supervision tree.

**Auto-generated id retrieval.** `start_link` and `start_agent` always return `{:ok, pid}` (GenServer contract). Callers who need the auto-generated id read it from the `subscribe/1` snapshot or via `get_state(pid, :id)`.

**Start opt errors.** The following combinations are rejected during `init/1`:

| Combination                         | Error                                    |
|-------------------------------------|------------------------------------------|
| `:new` without `:store`             | `{:error, :store_required}`              |
| `:load` without `:store`            | `{:error, :store_required}`              |
| Both `:new` and `:load`             | `{:error, :conflicting_opts}`            |
| `:new "x"` where "x" already exists | `{:error, :already_exists}`              |
| `:load "x"` where "x" not found     | `{:error, :not_found}`                   |
| `:load` with `:tree` or `:meta`     | `{:error, {:invalid_load_opts, fields}}` |

### Subscription

```elixir
{:ok, snapshot} = Omni.Agent.subscribe(pid)
:ok             = Omni.Agent.unsubscribe(pid)
```

Always explicit. The prompt-auto-registers-listener behavior from the current agent is removed — order-dependent magic doesn't survive the multi-subscriber model.

Subscribe returns a `%Omni.Agent.Snapshot{}`:

```elixir
%Omni.Agent.Snapshot{
  id:              String.t() | nil,
  model:           Model.t(),
  system:          String.t() | nil,
  tools:           [Tool.t()],
  tree:            Omni.Agent.Tree.t(),
  opts:            keyword(),
  meta:            map(),
  status:          :idle | :running | :paused,
  step:            non_neg_integer(),
  partial_message: [content_block] | nil,
  paused:          {reason :: term(), ToolUse.t()} | nil
}
```

Essentially `%State{}` minus `:private`, plus `:partial_message` and `:paused`. `:opts` is included because it carries surfaces subscribers care about (model selection, thinking level, etc.). `:paused` is populated iff `status == :paused` so late joiners can render the pause UI without catching a missed `:pause` event — the tuple shape matches the `:pause` event data so subscribers reuse a single pattern.

Late joiners subscribe mid-turn: the snapshot contains any `partial_message` streamed so far. Subsequent streaming events continue without gap.

Dead subscribers are reaped via `Process.monitor` — no manual unsubscribe needed for crashed consumers.

### Turn operations

```elixir
:ok = Omni.Agent.prompt(pid, content, opts \\ [])
:ok = Omni.Agent.cancel(pid)
:ok = Omni.Agent.resume(pid, decision)
```

Behavior unchanged. `prompt` while running/paused still stages for the next turn boundary (steering).

### Tree operations

```elixir
:ok = Omni.Agent.navigate(pid, node_id)         # set active path
:ok = Omni.Agent.regenerate(pid)                # re-run from current head
```

Only valid when idle; `{:error, :streaming}` while running or paused.

`navigate/2` is unrestricted — any node is reachable, including abandoned branches with dangling tool_uses. Validation happens at action time (`prompt`/`regenerate`), not traversal.

`regenerate/1` behaviour by head state:

| Head state                  | `regenerate/1` action                               |
|-----------------------------|-----------------------------------------------------|
| Assistant (text only)       | New assistant sibling from parent                   |
| Assistant (with tool_use)   | New assistant sibling from parent                   |
| User                        | Runs step from head (generates assistant response)  |

`regenerate` at a user head doubles as the retry API for "HTTP error left a dangling user message" — navigate to the user node, regenerate.

`prompt/3` validates head state: it accepts content on an assistant head or empty/root, and accepts `ToolResult` content blocks when the head ends in a tool_use. Invalid combinations return `{:error, :invalid_head}`. *(Deferred past Phase 2 — see Phase 2 notes.)*

**No `edit/3` API.** Compose `navigate(parent_id)` + `prompt(new_content)` — two calls, same outcome, no new surface to maintain. `regenerate` is kept because it's semantically distinct (no new user message added).

**No `regenerate/2` API.** Originally spec'd with a `node_id` argument; dropped during P2 because the same outcome composes from `navigate/2` + `regenerate/1` with cleaner event semantics (a single `:tree` event per navigation). Can be revisited if a use case surfaces.

### Inspection / configuration

```elixir
state = Omni.Agent.get_state(pid)
value = Omni.Agent.get_state(pid, key)

:ok = Omni.Agent.set_state(pid, opts)                 # keyword list, atomic
:ok = Omni.Agent.set_state(pid, field, value_or_fun)  # single field

:ok = Omni.Agent.add_tool(pid, tool)
:ok = Omni.Agent.remove_tool(pid, name)
```

**Settable fields:** `:model`, `:opts`, `:system`, `:tools`, `:meta`.
**Not settable:** `:id`, `:tree`, `:private`, `:status`, `:step`.

`:tree` is deliberately not settable — the agent is the source of truth for conversation state. Fork use cases pass `:tree` at startup to create a new agent with initial state.

`add_tool`/`remove_tool` are conveniences because tools are the most commonly mutated list. Everything else mutates cleanly through `set_state` (including the function form for map/list updates).

### Persistence management

```elixir
{:ok, summaries} = Omni.Agent.Store.list(opts)
:ok              = Omni.Agent.Store.delete(id, opts)
exists?          = Omni.Agent.Store.exists?(id, opts)
```

`Store.delete` terminates any live agent with that id before wiping storage.

---

## Start semantics

Three modes, resolved from opts at `init/1`:

- **Ephemeral** — no `:store` opt. `:id` is `nil`. Nothing persisted. Tool-spawned subagents and one-offs.
- **New** — `:store` opt present, `:new` absent or provides an explicit id. Creates a fresh agent. Auto-generated id if `:new` omitted (via Store callback). Errors if the explicit id already exists.
- **Load** — `:store` + `:load "x"`. Hydrates state from the store. Errors if not found.

Opt validation rules are listed under "Start opt errors" in the table above. Beyond those, opts are filtered per-field based on mode.

### Opts on load

Three categories:

**Runtime-only** — always from opts, never persisted:

- `:tools` (functions aren't serializable; caller always supplies)
- `:tool_timeout`, `:store`, callback module, subscribers

**Overridable** — persisted; caller's value wins when both present:

- `:model`
- `:system`
- `:opts`

Legitimately updatable at load time (app pushed a new system prompt version; user picked a different model). Effectively equivalent to `load-then-set_state` in a single call. The overridden value is re-persisted on the next save.

**Owned** — persisted; caller cannot pass these with `:load`:

- `:tree` — conversation state. Overriding at load is semantically broken.
- `:meta` — app-attached data. Updates happen via `set_state/2` after load.

Passing `:tree` or `:meta` alongside `:load` returns `{:error, {:invalid_load_opts, [...]}}`. For forks, start a *new* agent with `store: s` (no `:load`) and pass the seed `:tree`.

### Model resolution (lenient on load)

1. Try to resolve the persisted model ref via `Omni.get_model/2`.
2. If that fails and caller provided `:model` in opts, use that.
3. If both fail, `{:error, :model_not_found}`.

Covers "app removed a model between sessions" without ceremony from the caller. Callers are encouraged to pass `:model` at every load as a safety net.

### Registry conflicts

`Supervisor.start_agent(store: s, load: "x")` when "x" is already registered returns `{:error, {:already_started, pid}}` (standard `via`-tuple semantics). Callers who want find-or-connect:

```elixir
case Omni.Agent.Supervisor.start_agent(store: s, load: "x") do
  {:ok, pid} -> pid
  {:error, {:already_started, pid}} -> pid
end
```

### Load-if-exists-else-create

There is no magic fallback. Callers who want that pattern compose explicitly:

```elixir
if Omni.Agent.Store.exists?("x", store: Store.FileSystem) do
  Omni.Agent.Supervisor.start_agent(store: Store.FileSystem, load: "x")
else
  Omni.Agent.Supervisor.start_agent(store: Store.FileSystem, new: "x", model: m)
end
```

---

## Tree

Ported from `OmniUI.Tree` → `Omni.Agent.Tree`. Self-contained branching data structure — pure data, no process. Public API retains:

- `push/3`, `push_node/3` — append to active path
- `navigate/2` — set active path by walking to root (`nil` clears)
- `extend/1` — walk head to leaf following cursors
- `messages/1` — flatten active path to `[Message.t()]` (used by the server when building `%Context{}`)
- `children/2`, `siblings/2`, `path_to/2`, `roots/1`
- `head/1`, `get_node/2`, `get_message/2`, `size/1`, `usage/1`
- `new/1` — reconstruct from saved parts
- `Enumerable` — iterates active path root-to-leaf

A tree with no branches is a degenerate flat list — the linear case is subsumed at zero cost.

### Per-message commit

Each message commits to the tree as soon as it's complete:

- User prompt on turn start
- Assistant message on step complete (from `:step`)
- Tool-result user message after executor finishes
- Continuation user message on `{:continue, prompt, state}` from `handle_turn`

`partial_message` only holds the in-flight assistant message's content blocks. `nil` between steps (during tool execution) and when not streaming.

### Cancel / error semantics

The tree is **append-only**. Cancel and error rewind the active-path cursor to the parent of `turn_start_node_id` — i.e. to the pre-turn head.

- Messages from the cancelled/errored turn stay in the tree as an abandoned branch
- The active path excludes them, so subsequent LLM calls never see dangling tool_uses (Anthropic rejects that state)
- The abandoned branch is available via navigation for inspection later
- Persistence keeps the abandoned branch (it was saved as it accumulated)

The old "pending messages discarded on cancel/error" model is replaced by cursor rewind, which is semantically equivalent but scales naturally to branching.

### Tree mutations during streaming

`navigate/2` and `regenerate/2,3` return `{:error, :streaming}` while the agent is running or paused. Consumers cancel first if they want to branch mid-turn.

---

## Events

Events arrive as `{:agent, pid, type, data}` to all subscribers.

### Unchanged

Streaming (pass-through from `stream_text`):

```
:text_start, :text_delta, :text_end
:thinking_start, :thinking_delta, :thinking_end
:tool_use_start, :tool_use_delta, :tool_use_end
```

Lifecycle:

```
:pause         # {reason, %ToolUse{}}
:tool_result   # %ToolResult{}
:step          # %Response{}   — per-step response
:continue      # %Response{}   — turn continuing
:stop          # %Response{}   — turn complete
:cancelled     # %Response{}
:retry         # reason
:error         # reason
```

### New

```
:message   # %Message{}                          — message appended to tree
:node      # %{id, parent_id, message, usage}    — active-path append (tree-aware)
:tree      # %Omni.Agent.Tree{}                  — non-incremental change (navigate/regenerate)
:config    # %{model, system, tools, opts, meta} — persisted-field change (any source)
:store     # {:error, {op, reason}}              — persistence operation failed
```

`:store` fires only on errors — `{:error, {:save_tree, reason}}`, `{:error, {:save_state, reason}}`, `{:error, {:delete, reason}}`. Success is assumed silent (most subscribers don't care; errors need visibility). Subscribers building durability audits can wrap the Store adapter themselves.

### When `:config` fires

`:config` is the canonical signal for "any persisted field changed." It fires whenever one of `:model`, `:system`, `:tools`, `:opts`, `:meta` changes, regardless of source:

- Explicit `set_state/2,3` calls
- Callback-returned state (e.g. a `handle_tool_result/2` that mutates `:meta`)
- `add_tool/2` / `remove_tool/2`

The server diffs persisted fields on each callback return and fires `:config` + triggers `save_state` if any changed. `:private` is excluded from the diff (runtime-only, not broadcast).

### Event hierarchy

Lifecycle events form a natural hierarchy for consumers at different granularity:

```
:message → :step → :stop / :continue / :cancelled
```

Tree events layer tree-aware analogues on top for consumers building a local tree mirror:

```
:node (per append) → :tree (non-incremental)
```

Consumers who don't care about branching listen to `:message` (and step/turn events). Tree-aware consumers listen to `:node` and `:tree`. `:message` and `:node` do fire in parallel — the small duplication clarifies intent and keeps the two listener categories clean.

`:config` fires once per `set_state/2,3` call regardless of how many fields changed, carrying the new merged values for subscribers to replace their local cache.

---

## Store

Pluggable persistence via a behaviour. Store is always passed at start time — there is no global config. Ephemeral agents (no `:store` opt) don't persist anything.

### Behaviour

```elixir
@type state_data :: %{
  tree:   Tree.t(),
  model:  Model.ref(),
  system: String.t() | nil,
  opts:   keyword(),
  meta:   map()
}

@callback generate_id() :: String.t()
@callback save_tree(id :: String.t(), tree :: Tree.t(), opts :: keyword()) :: :ok | {:error, term()}
@callback save_state(id :: String.t(), state :: state_data(), opts :: keyword()) :: :ok | {:error, term()}
@callback load(id :: String.t(), opts :: keyword()) :: {:ok, state_data()} | {:error, :not_found}
@callback exists?(id :: String.t(), opts :: keyword()) :: boolean()
@callback list(opts :: keyword()) :: {:ok, [summary()]}
@callback delete(id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
```

Each store picks its own id format via `generate_id/0` — FileSystem can use ULIDs (sortable, nice for `list/1`), DETS might use integers, a Postgres adapter might use UUIDs. The framework does not pre-decide.

Opts recognized across adapters:

- `:new_node_ids` — hint for `save_tree` to append only those nodes (JSONL-friendly)
- `:limit`, `:offset` — for `list`

### What's persisted

- Tree (incremental via `save_tree`)
- Model (as `ref`; lenient on load)
- System prompt
- Opts (all inference opts — no distinction between "runtime" and "persistent" opts)
- Meta

### What's not persisted

- Tools (functions aren't serializable; always caller-supplied)
- Callback module (code, not data)
- Subscribers
- `:private` state
- `:status`, `:step` (runtime-only)

### Write-through semantics

- Tree — saved on each append via `save_tree(id, tree, new_node_ids: [id])`
- State — saved on each change to persisted fields (from `set_state`, callback returns, or `add_tool`/`remove_tool`), via `save_state`
- Errors broadcast a `:store` event (`{:error, {op, reason}}`) so subscribers know persistence diverged from in-memory state. Events continue firing — in-memory state is still the truth for the live session. Return values of triggering APIs also carry the error for callers who want to surface it.

### Bundled adapters

- `Omni.Agent.Store.FileSystem` — JSON / JSONL per-agent directory. Ported from `OmniUI.Store.FileSystem` with typed state shape.
- `Omni.Agent.Store.DETS` — optional, Phase 3 decision (ship alongside FileSystem, or defer until JSON format proves painful).

---

## Supervisor & Registry

Auto-started via `omni_agent`'s Application module:

```elixir
children = [
  {Registry, keys: :unique, name: Omni.Agent.Registry},
  Omni.Agent.Supervisor,
  # ...
]
```

Cost is negligible when unused. Consumers get `Supervisor.start_agent/2` working out of the box.

`Omni.Agent.Supervisor` is a `DynamicSupervisor` wrapper. Supervised agents use `restart: :temporary` — crashed agents aren't auto-restarted. Partial streaming state is lost on crash; persisted state survives. Next `start_agent` call loads fresh.

---

## Lifecycle

- `start_link` agents live as long as their caller (linked)
- `Supervisor.start_agent` agents live indefinitely; they terminate when the idle timer fires AND no subscribers remain AND no turn is streaming ("don't terminate while cooking")
- Idle timeout is configurable per-agent; default TBD (likely 5–15 min)
- `Store.delete(id)` terminates any live agent with that id before wiping storage
- Crashed supervised agents aren't restarted — next `start_agent` loads from persistence

---

## Phases

Build and test incrementally. Each phase is shippable.

### Phase 1 — Core agent changes ✅ Completed

- Remove `:listener` start opt and `listen/2` function entirely (breaking change; update `agent.ex` moduledoc / README / CHANGELOG)
- Add `subscribers :: MapSet.t(pid)` to server state with `Process.monitor` reaping on DOWN
- `subscribe/1` returns `{:ok, %Omni.Agent.Snapshot{}}`; `unsubscribe/1` returns `:ok`
- Subscribe is atomic within the server: snapshot capture and subscriber-add happen in the same `handle_call` clause so no streaming info message can interleave between them
- `:id` field added to State and Snapshot; always `nil` in P1 (populated from P3 once Store lands)
- Decompose `:context` field into `:system` + `:tools` + `:tree` (flat `[%Message{}]` in P1; Tree struct in P2)
- Final `%Omni.Agent.Snapshot{}` struct shape (including `:opts`, `:partial_message`, `:paused` — fields populate across phases; no re-shape later)
- `partial_message` field on server state, accumulated from streaming deltas. Reset to `nil` on `:step`, cancel, error. Populated from first streaming content block of the next step.
- `:message` event fires when a message is complete and added to `:tree`:
  - User messages — on `prompt/3` append and after executor produces a tool-result message
  - Assistant messages — on `:step` complete (same time as `:step`, fired immediately before `:step`)
- Mid-turn catchup: snapshot carries `partial_message` and `paused`; subsequent events continue without gap

**Key tests:**

- Subscribe returns a snapshot; subsequent events arrive on the subscriber
- Multi-subscriber broadcast; crashed subscribers reaped via DOWN
- Mid-turn catchup: stub slow step, subscribe mid-stream, assert snapshot status is `:running` AND every subsequent delta reaches the subscriber in order (proves the atomicity of snapshot+subscribe-add)
- Pause catchup: pause the agent, subscribe, assert `snapshot.paused` carries `{reason, tool_use}` and `snapshot.status == :paused`
- `:message` event fires for user (on prompt append), assistant (on `:step`), and tool-result user message
- `partial_message` resets to `nil` on cancel and error
- No auto-register on `prompt` (explicit subscribe only); `:listener` / `:context` start opts rejected with `{:invalid_opt, key}`

**Out of scope P1:** tree, persistence, registry/supervisor, navigate/regenerate, `:node`/`:tree`/`:config`/`:store` events, tool helpers, `:new`/`:load` start opts, auto-generated id

**Notes / refinements during implementation:**

- **`:paused` shape is a tuple, not a map.** Originally specced as `%{reason, tool_use}`; shipped as `{reason, tool_use}` to match the `:pause` event data so subscribers reuse a single pattern match across event and snapshot.
- **ToolUse partial blocks are placeholders until `:tool_use_end`.** Text/thinking deltas accumulate into the in-progress block's `text` field as they arrive, but tool-use input arrives as incrementally-built JSON that can't be parsed until the block ends. The `%ToolUse{}` placeholder is created at `:tool_use_start` with `id` + `name` + `input: %{}` and replaced with the fully-formed struct at `:tool_use_end`. A subscriber that wants live tool-input rendering should also listen to `:tool_use_delta` events.
- **`:messages` is accepted as an alias for `:tree` at start time.** Purely migration ergonomics; will be dropped in P2 when the Tree struct lands.
- **Legacy start opts fail loudly.** `:listener` and `:context` return `{:error, {:invalid_opt, key}}` from `init/1` rather than being silently dropped. Makes migration visible.
- **Rejected fields in `set_state`.** `:context` and `:tree` are not settable. `:context` returns `{:invalid_key, :context}` (from the keyword-list form) or `{:invalid_field, :context}` (from the single-field form). Same for `:tree`.
- **Test helpers auto-subscribe the test process.** `start_agent`/`start_agent_with_module` in `test/support/agent_case.ex` subscribe the calling test pid by default. Opt out with `subscribe: false`. Not part of the library surface — purely a test-suite convenience to avoid boilerplate in every test.

### Phase 2 — Tree ✅ Completed

- Port `OmniUI.Tree` → `Omni.Agent.Tree` (port tests with namespace swap)
- Tree replaces flat message list in state and snapshot
- Per-message commit to tree on append
- `turn_start_node_id` tracking for cancel/error rewind and per-turn response slices
- `:node` event on active-path append (carries `%{id, parent_id, message, usage}`)
- `:tree` event on non-incremental structural change
- `navigate/2`, `regenerate/1` APIs
- Tree mutations during streaming return `{:error, :streaming}`
- Cancel/error rewind active-path cursor; tree stays append-only

**Key tests:**

- Tree module tests (ported from `OmniUI.TreeTest`) — 73 tests
- `prompt/3` appends user node, fires `:node`, subsequent step appends assistant via `:node`
- `:step` → assistant message pushed; tool results → tool-result user message pushed
- `navigate/2` updates active path, emits `:tree`
- `regenerate/1` re-runs from active head; new assistant is sibling of previous
- Branching preserved across navigate + regenerate
- Cancel/error rewinds cursor; abandoned branch still reachable via navigate
- Tree mutations while streaming return `{:error, :streaming}`
- `turn_start_node_id` survives pause/resume (final `:stop` response carries the whole turn slice)

**Notes / refinements during implementation:**

- **`regenerate/2` dropped.** The design originally included `regenerate(pid, node_id)` as an atomic navigate+regenerate. During implementation we found it emits two `:tree` events (one for the explicit navigate, one for the implicit navigate-to-parent when the head is an assistant). Since callers can compose the same operation with `navigate/2` + `regenerate/1` at negligible cost and with cleaner event semantics, `regenerate/2` was removed. Can be revisited if real use cases surface.
- **`prompt/3` head-state validation deferred.** The design specifies `prompt/3` accepts content only on empty/assistant heads and `ToolResult` blocks on tool_use heads. Phase 2 ships without this validation — callers can currently push invalid sequences via `navigate` + `prompt`, and the LLM rejects them downstream. Scheduled to land alongside the persistence work (P3) or whenever real need arises.
- **Executor-crash path now routes through `handle_error/2`.** Pre-P2, executor crashes unconditionally reset the turn and emitted `:error`. P2 follow-up: mirror the step-crash pattern — call `handle_error`, respect `{:retry, state}` (re-spawn the executor with the preserved `approved_uses`) and `{:stop, state}` (rewind + reset + `:error`). Restores symmetry with the step path.
- **Per-turn `usage` derived from tree nodes, not a parallel counter.** The old `pending_usage` accumulator was removed; `turn_usage/1` walks the active-path slice from `turn_start_node_id` and sums node usages. Keeps the tree as the single source of truth.
- **Event ordering for rewind: `:tree` before `:cancelled` / `:error`.** Structural change is signalled first, lifecycle event follows. Subscribers that mirror tree state apply the rewind before rendering the terminal event.
- **`:continue` response excludes the continuation user message.** Preserved from the pre-tree behaviour. The `:continue` response is the turn slice "so far" (user prompt → assistant of the completed step). The continuation user message is pushed after, and the final `:stop` response carries the full extended slice including it. Semantically consistent with step/turn boundaries: a continuation without a following assistant would be a partial step, not a turn.
- **Node id algorithm kept as `size + 1`.** Briefly considered a separate `:next_id` counter for robustness against manual node deletion, but under the append-only invariant `size + 1` is strictly safer (no risk of the counter drifting from the node map). Integer ids are cheap in events, in the `new_node_ids` persistence hint, and readable in test output; random ids (ULID/UUID) deferred until cross-agent tree merging becomes a real need.

### Phase 3 — Persistence + Supervisor

- `Omni.Agent.Store` behaviour + `Omni.Agent.Store.FileSystem`
- `Omni.Agent.Supervisor` + `Omni.Agent.Registry`
- `omni_agent` Application module auto-starts both
- `Omni.Agent.Supervisor.start_agent/2`
- Start semantics: per-field category policy, four init outcomes, model fallback
- Write-through: `save_tree` on append, `save_state` on config change
- `Store.list/1`, `Store.delete/1`, `Store.exists?/2`
- Idle termination timer (supervised agents only)
- DETS adapter decision during this phase (ship or defer)

**Key tests:**

- Round-trip: create → terminate → `start_agent(id)` reloads tree/system/opts/meta/model
- Incremental tree save: `save_tree` receives `new_node_ids` hint for appends
- State conflict: `start_agent(id: "x", tree: t)` with data present errors
- Overridable fields: `start_agent(id: "x", model: m2)` with persisted m1 uses m2; persists m2 on first save
- Model fallback: unresolvable persisted ref + caller `:model` opt → caller wins
- Registry conflict: second `start_agent(id: "x")` returns `{:already_started, pid}`
- `Store.delete` terminates live agent + wipes storage
- No-op adapter: `start_link`/`save_state` work without persistence
- Save errors: adapter returns `{:error, _}`; agent doesn't crash
- Idle timer: fires only when no subscribers AND no turn streaming

### Phase 4 — Config events, tool helpers, lenient model resolution refinements

- `:config` event fires on `set_state` changes to `:model` / `:system` / `:opts` / `:meta` / `:tools`
- `add_tool/2`, `remove_tool/2`
- Confirm lenient model resolution covers both load-time and `set_state`-time failures

**Key tests:**

- Each `set_state` call that touches a persisted field fires one `:config` event with merged state
- `add_tool`/`remove_tool` update the agent's tool list and fire `:config`
- Unresolvable model on `set_state(model: ...)` logs + returns error, doesn't crash

### Not in these phases (separate workstreams)

- Wiring into `omni_ui` (follows P4)
- Moving artifacts / REPL tools into `omni_agent` (stay in `omni_ui`)
- Title auto-generation (stays in `omni_ui`)
- Cross-node PubSub or distributed agents

---

## Removed / superseded ideas from previous session.md

- **`Omni.Session` process wrapping Agent** — replaced by unified Agent
- **Remove `:meta` field** — `:meta` stays; title and app data live there
- **`edit/3` API** — compose `navigate` + `prompt`
- **`update/2` for session-level config** — use `set_state/2,3`
- **`thinking` as first-class field** — stays an inference option in `:opts`
- **Consumer adds Registry and Supervisor to their own app tree** — now auto-started by `omni_agent`'s Application module

### Superseded during design discussion

- **Load-or-create based on id presence** — replaced by explicit `:new` / `:load` start opts; no magic dispatch
- **Global `Omni.Agent.Store` config** — removed; store is always passed at start time
- **`:id` always present, auto-generated if absent** — `:id` is `nil` for ephemeral agents; generation moved to the Store (`generate_id/0` callback)
- **Framework-level ULID vs UUID decision** — deferred to per-Store choice
- **`:state_conflict` error** — replaced by `:already_exists`, `:not_found`, `{:invalid_load_opts, [...]}`
- **`:scope` opt on Store** — dropped; apps namespace their own ids if multi-tenant
- **`:opts` excluded from Snapshot** — included (subscribers need model/thinking-level info)
- **`:config` fires only on explicit `set_state`** — fires on any persisted-field change, including callback-returned state (server diffs on callback return)
- **Silent persistence errors** — replaced by `:store` event on error
- **First-prompt auto-listener** — removed; all subscribers call `subscribe/1` explicitly
- **`start_link` returning `{:ok, pid, id}`** — not possible (GenServer contract); retrieve id via snapshot

---

## Module layout

```
lib/omni/
├── agent.ex                          # Public module: behaviour, use macro, public API
└── agent/
    ├── application.ex                # Starts Registry + Supervisor
    ├── state.ex                      # Public state struct
    ├── snapshot.ex                   # Snapshot struct returned by subscribe/1
    ├── server.ex                     # Internal GenServer (@moduledoc false)
    ├── step.ex                       # (existing) Step task
    ├── executor.ex                   # (existing) Executor task
    ├── tree.ex                       # Branching message tree (ported)
    ├── supervisor.ex                 # DynamicSupervisor + start_agent/2
    ├── registry.ex                   # Registry wrapper (or just documented setup)
    ├── store.ex                      # Store behaviour + public API
    └── store/
        ├── file_system.ex            # JSON/JSONL adapter (ported)
        └── dets.ex                   # (optional) DETS adapter
```

---

## Open items to resolve during implementation

- **DETS adapter** — ship alongside FileSystem or defer. Default: defer unless JSON format proves painful.
- **Idle timeout default** — pick a reasonable value (likely 5–15 min). Tests use ~50ms.
- ~~**`turn_start_node_id` lifecycle across pause/resume**~~ — resolved in P2: cursor survives pause/resume untouched (test in `pause_resume_test.exs` asserts the final `:stop` response carries the whole turn slice).

---

## Dependencies

- `omni ~> 1.2.1` (or later) for `Omni.Codec` used by the FileSystem store adapter
  - Version 1.2.1 isn't released yet — `Omni.Codec` is on main but post-1.2.0
  - During development, use `{:omni, path: "../omni"}`; switch to hex before releasing
- `Plug` (test only) — already present, for `Req.Test` plug-based mocking

---

## Reference files in omni_ui

Port candidates (copy, rename namespace, adapt shape):

- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui/tree.ex` → Phase 2
- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui/store.ex` → Phase 3
- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui/store/file_system.ex` → Phase 3
- Tests: `/Users/aaron/Dev/ai/omni_ui/test/omni_ui/tree_test.exs` and `/Users/aaron/Dev/ai/omni_ui/test/omni_ui/store/file_system_test.exs`

Study for patterns (don't port directly):

- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui.ex` — `start_agent/2`, `update_agent/2`, tool normalization, lenient model resolution
- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui/handlers.ex` — current-turn accumulation logic, tree push on `:stop`, edit/regenerate flow
- `/Users/aaron/Dev/ai/omni_ui/lib/omni_ui/agent_live.ex` — session routing, persistence integration
