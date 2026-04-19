# Session Design

## Purpose

This document specifies the design of `Omni.Session`, a GenServer-based
wrapper around `Omni.Agent` that adds conversation lifetime, persistent
storage, a branching message tree, and navigation/regeneration semantics.

It captures decisions reached across a design exercise building on the
Agent redesign in `agent-redesign.md`. It is the spec for phase 4+ of the
roadmap.

## Scope

Covered:

- Session's responsibilities, state shape, storage adapter contract, tree
  schema, turn handoff, navigation, events, pub/sub, public API, and
  lifecycle.
- Open design questions that should be settled during or immediately before
  implementation.
- A phased implementation plan.

Not covered:

- `Omni.Session.Manager` (supervision, registry, idle-timeout
  self-termination) — parked as follow-up work, see Parked section.
- Replay / resume-from-sequence semantics for Session subscribers across
  process restarts — parked.
- Specific storage-adapter implementations beyond a reference filesystem
  adapter (SQLite, Postgres, Redis, etc. are out of scope for the initial
  implementation).

## Relationship to Agent

Two processes, two temporal scopes:

- **`Omni.Agent`** — ephemeral, single-turn-focused. Owns a model, context,
  private state, and an event stream. No identity beyond a pid, no
  persistence, no message tree. Source of truth for *in-flight* state
  during a turn.
- **`Omni.Session`** — longer-lived wrapper. Owns identity, persistent
  storage, a branching message tree, its own pub/sub, and navigation
  semantics. Starts and wraps a linked Agent. Source of truth for *at-rest*
  conversation state between turns.

The handoff happens at `:turn` events: the Agent commits pending messages
to `state.messages`; Session captures those commits into its tree and
persists.

Session uses **only the Agent's public API** — no reaching into internals.
The Agent is unaware of Session.

## Goals

- Keep Session's public surface small and well-scoped. Session is a wrapper
  with specific additions (tree, storage, navigation), not a second agent
  implementation.
- Make adapter authors' jobs easy: a clear, small behaviour contract that
  accepts Elixir terms and does not force a serialization choice.
- Keep the persistence model honest: writes are synchronous, errors surface
  as events, partial write failures do not halt the conversation.
- Preserve the Agent redesign's commit semantics: `state.messages` is
  always a valid history; turn cancels/errors leave persisted state
  untouched.

---

## Session responsibilities

In scope:

- Own a session identity (`id`), a human-friendly `title`, and a branching
  message tree.
- Start and link a single Agent process, forwarding its events to Session
  subscribers.
- Persist tree mutations and Agent configuration changes via a pluggable
  store adapter.
- Provide navigation, branching, and regeneration semantics built on top of
  `Agent.set_state` and `Agent.prompt`.
- Provide late-join snapshot consistency for Session subscribers.

Out of scope (belongs to `Omni.Session.Manager` or application layer):

- Supervision of many sessions concurrently.
- Registry-based lookup of sessions by id.
- Idle-timeout self-termination.
- Delete-by-id convenience that handles both running and stopped sessions.
- Title generation strategy (app-layer; Session exposes the slot).

---

## State shape

```elixir
%Omni.Session{
  id:                     String.t(),
  title:                  String.t() | nil,
  tree:                   Omni.Session.Tree.t(),
  store:                  Omni.Session.Store.t(),
  agent:                  pid(),
  subscribers:            MapSet.t(pid()),
  last_persisted_state:   map() | nil,
  regen_source:           Omni.Session.Tree.node_id() | nil
}
```

Only `id` and `title` are Session-owned fields visible in persistence.
Everything else is either runtime bookkeeping (`agent`, `subscribers`,
`regen_source`), derived state (`tree`, rehydrated on load), or
change-detection scaffolding (`last_persisted_state`).

**Deliberately absent:**

- No `meta` field. Arbitrary app-defined metadata is not a Session
  concern. If demand emerges, the chosen path is to add `:data` to Agent
  state (settable, persisted) rather than extend Session (see Parked).
- No mirror of Agent's `model`, `system`, `opts`. Those live in the Agent
  and are read via `Session.get_agent/1,2`. Session tracks
  `last_persisted_state` only for persistence change detection.

---

## Tree schema

### Module shape

```elixir
defmodule Omni.Session.Tree do
  @type t :: %__MODULE__{
          nodes:   %{node_id() => tree_node()},
          path:    [node_id()],
          cursors: %{node_id() => node_id()}
        }

  @type node_id :: non_neg_integer()

  @type tree_node :: %{
          id:        node_id(),
          parent_id: node_id() | nil,
          message:   Omni.Message.t(),
          usage:     Omni.Usage.t() | nil
        }
end
```

### Rules

- **Node IDs are auto-assigned**, generated by `Tree.push/2,3` as
  `map_size(nodes) + 1`. The Tree is the sole issuer; external callers
  never construct IDs.
- **Append-only.** Nodes may be added but never removed. Navigation and
  branching change the active `path`, never the node set.
- **Each node is a single message.** No tool-use/tool-result grouping at
  the tree level. Turn-grouping is a projection the UI/app computes from
  the flat node list.
- **`path`** is the active path — the sequence of node IDs from root to
  head, in order.
- **`cursors`** maps a node ID to its last-active child ID. When a user
  navigates away from a branch and back, `cursors` preserves which child
  path they were on.

### Key operations

Primitives already sketched in prior work (complete list in the Tree
module's implementation):

- `push/3`, `push_node/3` — append to active path (the latter also returns
  the new node ID).
- `navigate/2` — set active path by walking parent pointers from a given
  node back to root. Passing `nil` clears the path; a subsequent `push`
  creates a new root, so the tree may hold multiple disjoint roots.
- `extend/1` — extend the active path from the head to a leaf via cursors.
- `path_to/2` — walk parent pointers from a node to root.
- `children/2`, `roots/1` — structural queries.
- `messages/1`, `usage/1`, `head/1`, `size/1` — derived views.

Trees constructed on hydration via `Tree.new/1` from an enumerable of
nodes. The auto-ID counter derives from `map_size(nodes) + 1` live, so no
separate `next_id` field is stored.

---

## Storage

### Module shape

`Omni.Session.Store` is a **single module** holding both the adapter
behaviour (callbacks) and the dispatch functions. Adapter implementations
`@behaviour Omni.Session.Store`; callers invoke the dispatch functions
directly.

A "store" is a `{module, keyword()}` tuple — the adapter and its config.
This is the canonical shape everywhere: `Session.start_link` accepts it,
`Omni.Session.Store.*` dispatch functions take it as the first argument,
and applications stash it wherever they like.

```elixir
# Type
@type t :: {module(), keyword()}

# Passed to Session at start time
Session.start_link(store: {Omni.Session.Store.FileSystem, base_path: "/data"}, ...)

# Dispatched from Session internals
Omni.Session.Store.save_tree(store, session_id, tree, opts)
Omni.Session.Store.save_state(store, session_id, state_map, opts)
Omni.Session.Store.load(store, session_id, opts)
Omni.Session.Store.list(store, opts)
Omni.Session.Store.delete(store, session_id, opts)

# Called directly by applications (e.g. for deletion)
Omni.Session.Store.delete({Omni.Session.Store.FileSystem, base_path: "/data"}, "abc")
```

No global `Application.env` fallback. Applications holding store config
centrally wrap it in their own helper (e.g. `MyApp.Storage.store/0`).

### Adapter behaviour

```elixir
defmodule Omni.Session.Store do
  @type t :: {module(), keyword()}
  @type session_id :: String.t()

  @type state_map :: %{
          optional(:model)  => Omni.Model.ref(),
          optional(:system) => String.t() | nil,
          optional(:opts)   => keyword(),
          optional(:title)  => String.t() | nil
        }

  @type session_info :: %{
          id:         session_id(),
          title:      String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @callback save_tree(config :: term(), session_id(), Omni.Session.Tree.t(), keyword()) ::
              :ok | {:error, term()}

  @callback save_state(config :: term(), session_id(), state_map(), keyword()) ::
              :ok | {:error, term()}

  @callback load(config :: term(), session_id(), keyword()) ::
              {:ok, Omni.Session.Tree.t(), state_map()} | {:error, :not_found}

  @callback list(config :: term(), keyword()) :: {:ok, [session_info()]}

  @callback delete(config :: term(), session_id(), keyword()) ::
              :ok | {:error, term()}

  # Dispatch — callers invoke these; adapter module is the first element of
  # the tuple, config is the second.
  def save_tree({mod, config}, id, tree, opts \\ []),
    do: mod.save_tree(config, id, tree, opts)

  # ... save_state, load, list, delete follow the same pattern
end
```

`list/2` **must** honour `:limit` and `:offset` in `opts`:

- `:limit` — maximum number of results. Unlimited if absent.
- `:offset` — number of results to skip from the start. Defaults to 0.

Results are ordered by `updated_at` descending. Other filter options
(e.g. title substring, date range) are adapter-specific and live in the
same `opts` keyword — undefined opts are ignored.

Error reasons returned from `save_tree`, `save_state`, and `delete` are
adapter-specific. POSIX atoms (e.g. `:enoent`, `:eacces`) from
filesystem-backed adapters bubble up unwrapped.

### `state_map` shape

The four Session-owned keys:

```elixir
%{
  model:  Omni.Model.ref(),    # {:anthropic, "claude-sonnet-4-5"}
  system: String.t() | nil,
  opts:   keyword(),            # canonicalised (sorted) Omni opts
  title:  String.t() | nil
}
```

Prescribed, not free-form. Session is the sole caller of `save_state`,
and always passes the **full** subset — overwrite semantics, no partial
or merge operations at the behaviour level. `load/2` may return a map
with only a subset of keys present (e.g. a session that's had `set_title`
called but no agent config persisted yet); Session's load-mode resolution
merges against start opts.

Apps needing additional per-session metadata should wait on the `:data`
field on Agent state (parked).

### State categories and disjoint-keys merge

Persisted state falls into two categories:

| Category | Source | Write path | Trigger |
|---|---|---|---|
| Tree (nodes + path + cursors) | `%Omni.Session.Tree{}` | `save_tree` | Turn commits, navigation |
| State map (model/system/opts/title) | Agent config + Session title | `save_state` | Agent `:state` events (change-detected), `set_title/2` |

The two write paths operate on **disjoint keys**. Adapters that store
both in a single file or row (the FileSystem reference does) can safely
read-modify-write each side without conflict — this is not a semantic
merge, just splatting disjoint keys onto a previously-persisted record.

All writes go through the Session GenServer's mailbox and are serialised.
There is no concurrent-write scenario for a given session.

### Adapter data boundary

The adapter boundary is **Elixir terms**. `save_tree` receives an
`%Omni.Session.Tree{}`; `save_state` receives a `state_map` with the
prescribed keys (or a subset). Adapters may serialise to JSON, ETF,
DETS, SQL, or anything else.

`Omni.Codec` (from the `omni` package) is a helper for adapters that
want JSON-compatible output without losing Elixir-term fidelity — it
handles `Omni.Message` and `Omni.Usage` structs directly, and exposes
`encode_term`/`decode_term` for arbitrary terms. Adapters are not
required to use it.

### Persistence triggers (category-dependent)

State falls into two categories with different write-driver rules:

| Category | Mutator | Write trigger |
|---|---|---|
| Tree (nodes, path, cursors, title) | Session ops only | Keyed off **Session ops** — Session is sole mutator, so each mutating op explicitly triggers `save_tree` / `save_state` |
| Agent config (model, system, opts) | Agent (anyone with pid) | Keyed off **Agent `:state` events** with change detection — Agent is sole owner, Session only mirrors for persistence |

For the Agent-owned category, Session maintains a `last_persisted_state`
copy of the persistable subset:

```elixir
defp persistable_subset(session) do
  %{
    model:  Omni.Model.to_ref(session.agent_state.model),
    system: session.agent_state.system,
    opts:   Enum.sort(session.agent_state.opts),
    title:  session.title
  }
end
```

On Agent `:state` events, Session diffs `persistable_subset(new_state)`
against `last_persisted_state`. If different, `save_state` is called and
the cache updated. `opts` is canonicalized (sorted keyword list) in one
place to avoid spurious saves on equivalent-but-reordered inputs.

Title is persisted via the same path: `set_title/2` updates the field and
a `save_state` is triggered through the same digest mechanism.

### Write inventory

| Session op | `save_tree` | `save_state` |
|---|---|---|
| `start_link(new: _)` | no (first real mutation does it) | no |
| `start_link(load: _)` | no (`load` reads only) | no |
| `prompt/2,3` (eventual `:turn`) | yes (with `new_node_ids`) | no |
| `cancel/1` | no | no |
| `resume/2` (eventual `:turn`) | yes | no |
| `navigate/2` | yes (no `new_node_ids`) | no |
| `branch/2` (regen) | yes on nav, yes on `:turn` | no |
| `branch/3` (edit) | yes on nav, yes on `:turn` | no |
| `set_agent/2,3` (model/system/opts) | no | yes (via `:state` event) |
| `set_agent/2,3` (tools/private) | no | no (not in persistable subset) |
| `set_title/2` | no | yes |
| `add_tool/2`, `remove_tool/2` | no | no (tools not persisted) |

### Load-mode resolution

When `start_link(load: id)` is called and the store returns persisted
state, start opts reconcile against persisted values as follows:

| Field | Resolution |
|---|---|
| `model` | Persisted first. If unresolvable (e.g., model ref no longer exists), fall back to start opt. If both missing/unresolvable, `{:stop, :no_model}`. |
| `system` | Start opt wins. Falls back to persisted if start opt absent. |
| `opts` | Start opt wins. Falls back to persisted if start opt absent. |
| `tools` | Start opt only. Never persisted (function refs). |
| `tree` | Persisted only. No `tree:` start option. |
| `title` | Persisted only. `title:` start option is ignored on load. |
| `messages` (in `agent:` opts) | Silently ignored on load; messages derive from `Tree.messages(tree)`. |

Rationale: `model` has the strongest "this conversation was with X"
identity; other config fields naturally track app evolution and should
respect the app's current intent. Tree and title are persisted artefacts
of the conversation itself.

On `start_link(new: _)`, `agent: [messages: ...]` is **rejected** with
`{:error, :initial_messages_not_supported}` — the tree is the sole entry
point for messages, and initial-messages-via-agent-opts would desync tree
and agent.

### Error model

Store calls return `{:error, reason}` on failure. Session **never halts**
on store errors. On every store attempt, Session emits an event:

```elixir
{:session, session_pid, :store, {:saved, op}}
{:session, session_pid, :store, {:error, op, reason}}
```

Where `op` is one of `:tree | :state | :delete`. The `:saved` event fires
only after the adapter returns `:ok`. Subscribers that care about
persistence health (UIs wanting a "synced" indicator) can track both.

No automatic retry in v1. If the application needs retry semantics, it can
observe `:store` errors and call the mutating API again. Adding Session-level
retry is a future consideration.

### Write ordering

All store calls are **synchronous**, executed in the Session GenServer's
`handle_call` / `handle_info` clauses. Consequences:

- Writes serialize naturally through the mailbox.
- No cross-write ordering bugs.
- A slow store slows Session's event processing, but **not** the Agent
  (the Agent is a separate process and keeps streaming; Session just
  catches up with event forwarding after the write completes).

If a future adapter is unusually slow (remote/network store under load),
the user can wrap their adapter in a Task queue themselves or we revisit.

### Hydration sequence (`load:` mode)

1. Call `Store.load(store, id)`.
2. If `{:error, :not_found}`: `{:stop, :not_found}`.
3. Reconcile persisted `state_map` with start opts per Load-mode
   resolution rules.
4. Seed `last_persisted_state` from the reconciled persistable subset
   **before** starting the Agent, so the Agent's post-init `:state` event
   doesn't trigger a spurious `save_state`.
5. Start the Agent (linked) with the reconciled state.
6. Set Session's `tree` from the loaded tree.
7. Go idle, ready to `prompt`.

### FileSystem reference adapter

`Omni.Session.Store.FileSystem` is the reference implementation shipped
with the package. Per-session directory with two files:

```
base_path/
  {session_id}/
    nodes.jsonl     # tree nodes, one JSON-encoded node per line
    session.json    # path, cursors, state_map fields, timestamps
```

**`nodes.jsonl`.** Append-only when `:new_node_ids` is passed in `opts`;
full rewrite when absent. One node per line:

```json
{"id": 1, "parent_id": null, "message": {...}, "usage": {...}}
```

`message` and `usage` are serialised via `Omni.Codec.encode/1`.

**`session.json`.** Single merged file, written by both `save_tree`
(path + cursors + `updated_at`) and `save_state` (state_map fields +
`updated_at`). Keys are disjoint; merge is read-modify-write.

```json
{
  "path": [1, 3, 5],
  "cursors": [[1, 3], [3, 5]],
  "title": "My conversation",
  "model": ["anthropic", "claude-sonnet-4-5"],
  "system": "You are helpful.",
  "opts": {"__etf": "..."},
  "created_at": "2026-04-19T12:34:56Z",
  "updated_at": "2026-04-19T12:40:00Z"
}
```

Per-field encoding:

| Field | Encoding | Notes |
|---|---|---|
| `path` | JSON array of integers | |
| `cursors` | JSON array of `[k, v]` pairs | JSON maps can't key on integers |
| `title` | JSON string or `null` | |
| `model` | `[provider_string, model_id]` | Decoded via safe atom lookup against `Omni.Model` provider set |
| `system` | JSON string or `null` | |
| `opts` | `Omni.Codec.encode_term/1` wrapper | Keyword list with atoms and arbitrary values |
| `created_at`, `updated_at` | ISO8601 strings | Adapter-managed |

**Load behaviour.**

- `session.json` missing → `{:error, :not_found}`.
- `session.json` present but `nodes.jsonl` missing → `{:ok, %Tree{},
  state_map}`. Valid early state, e.g. `set_title` called before the
  first prompt.
- Partial `state_map` keys in `session.json` are returned as-is. Missing
  keys aren't defaulted — Session's load-mode resolution merges against
  start opts.

**Configuration.** `base_path` in the config keyword list:

```elixir
{Omni.Session.Store.FileSystem, base_path: "/path/to/sessions"}
```

No default; the adapter raises on an unset `:base_path`.

---

## Events

### Forwarding rule

All Agent events are re-tagged with the Session pid and forwarded to
Session subscribers:

```
{:agent, agent_pid, type, payload} → {:session, session_pid, type, payload}
```

Session subscribers see the Agent stream verbatim except for the tag
change. This includes streaming deltas, `:message`, `:step`, `:turn`,
`:pause`, `:retry`, `:cancelled`, `:error`, `:state`, `:tool_result`.

### Session-specific events

```elixir
{:session, pid, :tree,  %{tree: Tree.t(), new_nodes: [node_id()]}}
{:session, pid, :title, String.t() | nil}
{:session, pid, :store, {:saved, op}}
{:session, pid, :store, {:error, op, reason}}
```

- **`:tree`** — fired on *any* tree mutation. `new_nodes` lists IDs of
  newly-added nodes (empty list when the mutation is navigation only).
  Fires on turn commits, navigation, and branch/regen initiation.
- **`:title`** — fired after `set_title/2` mutation.
- **`:store`** — fired on store call completion (success or failure).

### Event ordering at turn commit

For a plain turn that adds messages to the tree:

```
prompt(session, "hi")
  → :message (user)       # forwarded from agent
  → streaming deltas ...  # forwarded from agent
  → :message (assistant)  # forwarded from agent
  → :step                 # forwarded from agent
  → :turn {:stop, ...}    # forwarded from agent, triggers tree commit
  → :tree %{tree, new_nodes: [N+1, N+2]}  # Session's own event, tree committed
  → :store {:saved, :tree}
```

`:turn` fires before `:tree` because `:turn` is what Session *observes*
to trigger the tree commit. Subscribers that want "logical turn boundary"
listen on `:turn`; subscribers that want "tree structure changed" listen
on `:tree`. They're different abstractions over the same instant.

---

## Snapshot

```elixir
%Omni.Session.Snapshot{
  id:    String.t(),
  title: String.t() | nil,
  tree:  Omni.Session.Tree.t(),
  agent: Omni.Agent.Snapshot.t()  # includes Agent state, pending, partial
}
```

Consumers compose the in-flight view as:

```
committed: Tree.messages(snapshot.tree)
in_flight: snapshot.agent.pending ++ List.wrap(snapshot.agent.partial)
full_view: committed ++ in_flight
```

**Duplication note.** `snapshot.agent.state.messages` is the active path
(Session set it via `Agent.set_state(messages: ...)` on navigation), which
is also derivable from `Tree.messages(snapshot.tree)`. They point to the
same message structs — zero memory cost, but consumers should treat the
tree as source of truth for committed structure and use `agent.pending` /
`agent.partial` only for in-flight streaming. Don't render
`agent.state.messages` directly.

### Late-join consistency

`Session.subscribe/1,2` is a `GenServer.call` that atomically builds the
snapshot and registers the subscriber in one `handle_call` clause. Any
event emitted after that point is delivered to the new subscriber.

For Agent events to be consistently reflected, Session's snapshot of
`agent: Agent.Snapshot.t()` is itself built via `Agent.get_snapshot/1` —
also atomic on the Agent side. The composition is consistent:
`tree` reflects committed-to-disk (and to-memory) state at the instant of
subscription; `agent.pending` and `agent.partial` reflect the Agent's
in-flight state at that same instant.

What Session does **not** provide: replay of events that fired before
subscription (persistent event log is parked), or snapshot consistency
across multiple Session lifetimes (if Session has been stopped and
restarted, there's no continuity beyond what the store holds).

---

## Pub/sub

Identical mechanism to Agent. Session holds a `MapSet` of subscriber
pids plus monitors for cleanup-on-death.

### API

- `Session.subscribe(session) :: {:ok, Snapshot.t()}` — subscribes caller.
- `Session.subscribe(session, pid) :: {:ok, Snapshot.t()}` — subscribes given pid.
- `Session.unsubscribe(session) :: :ok`
- `Session.unsubscribe(session, pid) :: :ok`

### Start-time convenience

```elixir
Session.start_link(subscribe: true, ...)         # subscribes caller
Session.start_link(subscribers: [pid1, pid2], ...) # subscribes given pids
```

---

## Navigation & branching

Session-only concepts (the Agent has no notion of a tree). Both
operations mutate the tree and synchronize the Agent via
`Agent.set_state(messages: path_messages)`.

All navigation and branching is **idle-only**. When a turn is in
flight (`:running` or `:paused`), these calls return
`{:error, :not_idle}` — use `cancel/1` or wait for the `:turn` event
first. Plain `prompt/2,3` continues to stage for steering when not
idle; navigation and branching do not.

### `navigate/2`

```elixir
Session.navigate(session, node_id) :: :ok | {:error, :not_found | :not_idle}
```

Sets the active path by walking parent pointers from `node_id` back to
root. Updates `cursors` for each node along the path (remembers which
child was last active). Triggers `Agent.set_state(messages: ...)` with
the path messages. Emits `:tree` event with empty `new_nodes`.

### `branch/2,3`

A single primitive, "branch from this node." The arity and the target
node's role determine the semantics:

| Call | Target role | Effect |
|---|---|---|
| `branch(session, user_id)` | user | Regenerate the turn rooted at this user message. Same content, new assistant response. |
| `branch(session, assistant_id, content)` | assistant | Extend from this assistant with new user `content`. Creates a new user + its turn as children of the assistant. |
| `branch(session, nil, content)` | — | Create a disjoint new root with the given user `content`. Atomic equivalent of `navigate(session, nil)` + `prompt(session, content)`. |

Other role/arity combinations error:

- `branch/2` on a non-user target → `{:error, :not_user_node}`
- `branch/3` on a non-assistant, non-nil target → `{:error, :not_assistant_node}`
- Either arity on an unknown node → `{:error, :not_found}`
- Either arity while not idle → `{:error, :not_idle}`

The rule is consistent: **"branch from X" always means X is the parent
of the new branch.** `branch/2` reuses the target's content, `branch/3`
requires new content. Since a valid conversation alternates user and
assistant messages, the target's role uniquely determines which arity
is legal.

Applications build higher-level UI concepts (edit a user message,
regenerate an assistant response) on top of this primitive — typically
by mapping an assistant-id click to `branch(parent_of_assistant)` for
regen, and a user-id click to `branch(parent_of_user, new_content)` for
edit.

**`branch/2` mechanics (regenerate a user's turn):**

1. Validate target is a user node; error otherwise.
2. Tree: set active path to include `user_id` (ends on the user).
   Cursors update along the path.
3. Agent: `set_state(messages: path_to(user_id) |> drop_last)` — agent
   sees the path up to but not including the user (ends on an assistant,
   or empty if the user is root).
4. Session records `regen_source = user_id`.
5. `Agent.prompt(agent, content_of(user_id))`.
6. Emit `:tree` with empty `new_nodes` (path changed, no new nodes yet).
7. On the resulting `:turn {:stop | :continue, response}` event, drop
   the leading user message from `response.messages` (it duplicates
   `user_id`) and push the remainder as children of `user_id`. Clear
   `regen_source`. Emit `:tree` with `new_nodes`.
8. On `:cancelled` or `:error`, clear `regen_source` without tree
   mutation. Tree path remains on `user_id`; the agent is idle again,
   and a subsequent call (navigate, branch, or prompt) will resync.

During steps 3–7 the tree path (ends on user) and the agent's messages
(end on user's parent) are deliberately out of sync. This resolves at
turn commit. Subscribers observing in-flight streaming should use the
agent snapshot's `pending`/`partial` for the in-flight view, as
specified in Snapshot.

If the turn produces a `{:continue, _}` mid-regen, the drop-leading-user
rule applies only to the first segment. Continuation segments push
normally from the head of the active path (the last message pushed in
the previous segment), not from `user_id`. `regen_source` is cleared
after the first segment.

**`branch/3` mechanics (extend from an assistant):**

1. Validate target is an assistant node; error otherwise.
2. Tree: set active path to `assistant_id` (ends on the assistant).
3. Agent: `set_state(messages: path_to(assistant_id))` — same path as
   the tree.
4. `Agent.prompt(agent, content)`.
5. Emit `:tree` with empty `new_nodes`.
6. On the resulting `:turn`, push all of `response.messages` as
   children of `assistant_id`. No drop applies. Emit `:tree` with
   `new_nodes`.
7. On `:cancelled` or `:error`, no tree mutation beyond the path
   change in step 2.

### Cursor updates on branch

Any mutation that changes the active path updates cursors. After a
`branch` turn commits, the cursor at the divergence point (the target
node) points to the first newly-pushed child. The new branch becomes
the default when navigating back to an ancestor and calling `extend/1`
— the intuition being "the most recent action is what you want next."

### Root and edge cases

- `branch/2` on a root user: agent messages = `[]`. Prompt with the
  user's content; turn's leading user is dropped; rest pushed as
  children of the root user.
- `branch(session, nil, content)` is the sugared form of
  `navigate(session, nil)` + `prompt(session, content)` — it clears
  the active path and prompts, producing a new disjoint root.

---

## Public API

### Lifecycle

- `start_link(opts)` — see Start options below.
- `stop(session)` — graceful shutdown. Storage retained.

### Turn control

Delegates to the wrapped Agent:

- `prompt(session, content)` / `prompt(session, content, opts)`
- `cancel(session)`
- `resume(session, decision)`

### Navigation

- `navigate(session, node_id)`
- `branch(session, user_node_id)` — regenerate the turn rooted at this
  user message.
- `branch(session, assistant_node_id, content)` — extend from this
  assistant with new user content (edit the next user message).

### Mutation

- `set_agent(session, opts)` — keyword list; delegates to
  `Agent.set_state/2`.
- `set_agent(session, field, value_or_fun)` — delegates to
  `Agent.set_state/3`.
- `set_title(session, title)` — sets title, persists via `save_state`,
  emits `:title` event.
- `add_tool(session, tool)` / `remove_tool(session, tool_name)` — helpers
  over `set_agent(:tools, ...)`. Tools are not persisted.

### Inspection

- `get_agent(session)` — returns `Agent.State.t()` (delegates to
  `Agent.get_state/1`).
- `get_agent(session, key)` — returns a single Agent state field.
- `get_tree(session)` — returns `Tree.t()`.
- `get_title(session)` — returns the title string or `nil`.
- `get_snapshot(session)` — returns `Session.Snapshot.t()`.

### Subscription

- `subscribe/1,2`, `unsubscribe/1,2`.

---

## Start options

```
:new                — binary() | :auto. New session with given (or generated) id.
:load               — binary(). Load existing session by id. Mutex with :new.
:agent              — keyword() | {module(), keyword()}. Agent start opts
                      (with optional callback module). Required.
:store              — {module(), keyword()}. Store adapter and config. Required.
:title              — String.t(). Initial title, new-mode only. Ignored on :load.
:subscribe          — boolean(). If true, subscribes caller.
:subscribers        — [pid()]. Subscribes given pids.
:name               — GenServer registration name.
:timeout, :hibernate_after, :spawn_opt, :debug  — standard GenServer options.
```

Defaults:

- Neither `:new` nor `:load` given → treated as `new: :auto` with a
  generated id.
- `:new` and `:load` together → `{:error, :ambiguous_mode}`.

### ID generation

Auto-generated IDs use:

```elixir
:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
```

22 characters, URL-safe, 128 bits of entropy. No external dependencies.
The format is documented in the moduledoc so applications building URL
schemes around the ID know what to expect.

No configurability in v1. Explicit IDs are supplied via `new: "my_id"`;
auto-generated IDs use the built-in helper.

---

## Validation & errors

| Return | Situation |
|---|---|
| `{:error, :ambiguous_mode}` | `:new` and `:load` both given |
| `{:error, :not_found}` | `load:` id not in store |
| `{:error, :no_model}` | `load:` resolution can't produce a model |
| `{:error, :initial_messages_not_supported}` | `new:` with `agent: [messages: _]` |
| `{:error, :not_idle}` | `navigate/2` or `branch/2,3` called during a running or paused turn |
| `{:error, :not_found}` | `navigate/2` or `branch/2,3` to unknown node |
| `{:error, :not_user_node}` | `branch/2` target isn't a user node |
| `{:error, :not_assistant_node}` | `branch/3` target isn't an assistant node |
| `{:error, reason}` from Agent | forwarded verbatim |

The duplicate-id race on `new:` with explicit id is **accepted as a known
edge case**. Two concurrent `start_link(new: "x")` calls can both succeed
if neither has written yet; the first one to persist "wins" and subsequent
writes may conflict. Resolving this requires either an adapter-level
`create_if_absent` primitive or a `Session.Manager` with process-level
deduplication. Both are parked.

### Agent crash behaviour

The Agent is linked to Session; Agent crash takes Session down with it.
No `trap_exit` in Session. Sessions are cheap to reopen via `load:`; if
something bad happened, the bad thing should surface, not be hidden.

---

## Parked / future work

Known items, deliberately excluded from the initial Session implementation:

### `Omni.Session.Manager`

A supervisor module providing:

- Named Registry for session-id → pid lookup.
- DynamicSupervisor for running session children.
- Convenience APIs: `Manager.start_session/1`, `Manager.find_session/1`,
  `Manager.delete_session/1` (stops running + deletes from store).
- Idle-timeout self-termination for sessions with no subscribers.

To be designed separately once Session proper is stable. The Manager
layers *on top of* Session without changing Session's API.

### `:data` field on Agent state

If demand emerges for app-defined per-session metadata (tags, UI hints,
integration IDs), the chosen path is to add a `:data` field to
`Omni.Agent.State` — settable via `Agent.set_state(:data, _)`, persisted
alongside model/system/opts in Session's persistable subset. Placing it
on Agent rather than Session benefits plain-Agent users too. Deferred
until a concrete consumer surfaces.

### Title auto-generation

A common pattern — auto-title a session after the first turn — can be
added as a start-time helper:

```elixir
Session.start_link(auto_title: :first_user_message_64, ...)
```

Or, more flexibly:

```elixir
Session.start_link(auto_title: &MyApp.summarize/1, ...)
```

Implemented as sugar over the existing subscribe-and-set-title pattern.
Parked until a clear convention emerges.

### Session.delete convenience

Currently deletion is two lines (`Session.stop/1` + `Store.delete/3`) or
one store call if the session isn't running. A `Session.delete(id)` that
handles both cases transparently requires knowing which sessions are
running — which is the Manager's job. Folds naturally into the Manager
design.

### Retry / queueing on store failure

In v1, store errors emit `:store {:error, ...}` events and the session
continues without retry. Future work may add Session-level retry policies
or a write-behind queue for high-latency adapters. Not needed for local
filesystem / SQLite / simple KV stores.

### Persistent event log / replay

Late-join consistency within a single Session lifetime is provided via
snapshots. A persistent event log that lets subscribers resume from a
sequence number after process restart is a qualitatively different
capability — parked.

---

## Open design questions

Items worth revisiting during implementation:

1. **`get_agent/2` key validation.** Should invalid keys return `nil` or
   `{:error, :invalid_key}`? Agent's `get_state/2` precedent should be
   followed.

2. **Streaming-time partial events on late-join.** The snapshot captures
   `agent.partial` at subscribe time. Is there a subsequent `:text_delta`
   event that overlaps with the delta already represented in `partial`?
   Verify this works cleanly with the Agent's snapshot+subscribe
   atomicity.

3. **Naming ambiguity with OTP.** `Omni.Session` collides with nothing in
   standard lib, but "session" is an overloaded term. Brief check that
   nothing in the Elixir ecosystem uses this name in a way that would
   clash in common client code (unlikely, but worth five minutes of
   grep).

---

## Implementation phases

Four phases, each landing in a working, tested state. They can be
separate PRs; dependencies flow in order.

### Phase 5 — `Omni.Session.Tree`

**Goal:** Implement the pure-data tree module.

**Key work:**

- `Tree` struct and all operations listed in Tree schema.
- `new/1` constructor from an enumerable of nodes (for hydration).
- `push/3`, `push_node/3` with auto-ID assignment.
- `navigate/2`, `extend/1`, `path_to/2`.
- Derived views: `messages/1`, `usage/1`, `head/1`, `size/1`, `children/2`,
  `roots/1`, `get_node/2`, `get_message/2`.
- Unit tests covering: sequential push, branching via navigate-then-push,
  cursor preservation across navigate-away-and-back, path walks, usage
  aggregation, empty-tree edge cases.

**Dependencies:** none.

**Acceptance:**

- All Tree operations pass unit tests in isolation.
- Branch scenario test: push A, B, C; navigate to A; push D (creating a
  branch); navigate to C via cursors; extend — verifies cursor and path
  behaviour.

### Phase 6 — `Omni.Session.Store` behaviour + reference adapter

**Goal:** Define the adapter contract and ship a reference filesystem
adapter.

**Key work:**

- `Omni.Session.Store` — single module holding the behaviour callbacks
  (`save_tree`, `save_state`, `load`, `list`, `delete`) and the dispatch
  functions. Canonical store shape is `{module, keyword()}`.
- `list/2` mandates `:limit` and `:offset` in `opts`.
- `Omni.Session.Store.FileSystem` reference adapter: per-session
  directory with `nodes.jsonl` (append-only, via `:new_node_ids` hint)
  and `session.json` (disjoint-keys merge written by both `save_tree`
  and `save_state`). `Omni.Codec` for message/usage serialisation;
  `model` encoded as plain JSON `[provider, id]` for inspectability;
  `opts` ETF-wrapped.
- Integration tests: create, save_tree (append + full rewrite), save_state
  (overwrite), load (round trip, partial state_map, empty-tree case),
  list (pagination, ordering), delete, error scenarios.

**Dependencies:** Phase 5.

**Acceptance:**

- Filesystem adapter round-trips a tree with branches and metadata
  losslessly.
- Adapter behaviour is documented clearly enough that a third party could
  implement SQLite or Postgres adapters from the spec alone.

### Phase 7 — Session core

**Goal:** The Session GenServer: lifecycle, Agent wrapping, turn-driven
persistence, pub/sub.

**Key work:**

- `Omni.Session` GenServer module.
- `start_link/1` supporting `:new`, `:load`, auto-gen id.
- Load-mode resolution rules.
- Linked Agent startup; event forwarding with re-tagging.
- Turn-commit → `save_tree` with `new_node_ids`.
- Agent `:state` event → change-detection → `save_state`.
- `last_persisted_state` seeding on hydration.
- `:store` events for save success/failure.
- Subscribe/unsubscribe with monitors and atomic snapshot.
- `Session.Snapshot` struct + `get_snapshot/1`.
- `stop/1` graceful shutdown.
- Turn control passthrough: `prompt/2,3`, `cancel/1`, `resume/2`.
- Inspection: `get_agent/1,2`, `get_tree/1`, `get_title/1`.
- Tests: new-session lifecycle, load-session hydration, single-turn
  persistence, multi-turn persistence, subscriber delivery, cancel/error
  non-persistence, load-mode resolution edge cases.

**Dependencies:** Phases 5 and 6.

**Acceptance:**

- A new session can be created, prompted, and its tree persisted. Restart
  the process, `load:` with the same id — full conversation restored.
- Concurrent subscribers receive identical event streams.
- Store errors do not halt the session; `:store {:error, _}` events fire.

### Phase 8 — Navigation, branching, and mutation APIs

**Goal:** Branching navigation and the full mutation surface.

**Key work:**

- `navigate/2` — idle-only; sets tree path + agent messages; emits
  `:tree` with empty `new_nodes`.
- `branch/2` (regen) — validates user target; navigates tree path to
  the user; sets agent messages to the user's parent path; prompts
  with the user's content; on `:turn`, drops the leading duplicate
  user from the response and pushes the rest as children of the
  target. Internal `regen_source` flag drives the drop.
- `branch/3` (edit) — validates assistant target; navigates tree path
  to the assistant; prompts with the new content; on `:turn`, pushes
  all messages as children of the target.
- `set_title/2` with `:title` event + `save_state`.
- `add_tool/2`, `remove_tool/2`.
- `:tree` events on all tree mutations (navigation, branch initiation,
  turn commit).
- Tests: `branch/3` produces a sibling user+turn under an assistant;
  `branch/2` produces a sibling assistant under a user; cursors track
  latest-active-child after branch; idle gate errors on non-idle;
  title persistence survives restart; `set_agent(model)` change-
  detection avoids spurious saves on navigation.

**Dependencies:** Phase 7.

**Acceptance:**

- Edit flow: prompt A, get response A'; `branch(A', "new content")`
  creates a new user sibling under A' with its own assistant response;
  tree structure and store contents verified.
- Regen flow: `branch(user_id)` produces a sibling assistant under the
  same user; original preserved; cursor updated to the new branch.
- Cursor navigation: navigate away and back preserves previous branch
  via cursors; after a branch, the new branch is the default on
  extend.
- Idle gate: navigate/branch during a running or paused turn returns
  `{:error, :not_idle}`.
- All mutation APIs covered with tests.

---

## Beyond Phase 8

See Parked section for follow-up work. Most immediate candidate:
`Omni.Session.Manager` with supervision, registry, idle-timeout, and
delete-convenience, designed as a separate phase once Session proper is
stable.
