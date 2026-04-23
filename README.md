# Omni Agent

**Stateful LLM agents for Elixir** — persistent, branching conversations, tool approval, steering, and multi-session management. Built on [Omni](https://github.com/aaronrussell/omni).

## Features

- 🧠 **Stateful agents** — lifecycle callbacks for tool approval, prompt steering, and custom turn control
- 🌳 **Branching conversations** — a message tree you can regenerate, edit, or switch between alternate replies
- 💾 **Pluggable persistence** — a `Store` behaviour with a filesystem reference adapter; bring your own for Postgres, S3, or anywhere else
- 🎛️ **Multi-session supervisor** — `use Omni.Session.Manager` for registry-backed multi-session apps with cross-session pub/sub
- 📡 **Streaming events** — text, thinking, and tool deltas plus lifecycle events arrive as process messages (LiveView-friendly)
- 🔁 **Resumable** — sessions persist model, opts, title, and full history; reopen by id and continue, or fork a new branch

## Installation

Add Omni Agent to your dependencies:

```elixir
def deps do
  [
    {:omni_agent, "~> 0.2"}
  ]
end
```

Omni Agent depends on `omni`, which provides the LLM API layer. Configure
your provider API keys as described in the [Omni
README](https://github.com/aaronrussell/omni#installation).

## The layers

Each layer is a standalone building block. Pick the one that matches the
scope of what you're building — you can stop at any level.

| Module | What is it |
| --- | --- |
| `Omni.Session.Manager` | many sessions — supervision, registry, live feed |
| `Omni.Session` | persistent conversation — branching, regen, navigation |
| `Omni.Agent` | stateful conversation — tools, callbacks, events |
| `Omni` | stateless LLM API — stream_text, tools, structs |

## Agents

An agent is a GenServer that owns a single conversation. You send prompts
in; streaming events come back as process messages.

### Quick conversation

```elixir
{:ok, agent} = Omni.Agent.start_link(
  model: {:anthropic, "claude-sonnet-4-6"},
  subscribe: true
)
:ok = Omni.Agent.prompt(agent, "Hello!")

receive do
  {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
  {:agent, ^agent, :turn, {:stop, _response}} -> IO.puts("\nDone!")
end
```

### Custom agents

Define a module with `use Omni.Agent` to customise behaviour through
lifecycle callbacks. All callbacks are optional with sensible defaults.
`init/1` receives the fully-resolved `%State{}` — bake in defaults
(system prompt, tools) or read per-invocation input from `state.private`:

```elixir
defmodule GreeterAgent do
  use Omni.Agent

  @impl Omni.Agent
  def init(state) do
    system = "You are a helpful assistant. The user's name is #{state.private.user}."
    {:ok, %{state | system: system}}
  end
end

{:ok, agent} = GreeterAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-6"},
  private: %{user: "Alice"}
)
```

### Tool approval

Pause on any tool use, inspect it, decide:

```elixir
defmodule SafeAgent do
  use Omni.Agent

  @impl Omni.Agent
  def handle_tool_use(%{name: "delete_" <> _}, state) do
    {:pause, :requires_approval, state}
  end

  def handle_tool_use(_tool_use, state), do: {:execute, state}
end

# Subscribers receive {:agent, pid, :pause, {:requires_approval, %ToolUse{}}}.
# Resume when the decision is made:
Omni.Agent.resume(agent, :execute)              # approve
Omni.Agent.resume(agent, {:reject, "Denied"})   # reject with error result
Omni.Agent.resume(agent, {:result, my_result})  # provide a result directly
```

### Autonomous agents

The difference between a chatbot and an autonomous agent is entirely in
the callbacks. Give it a completion tool and loop until the model calls it:

```elixir
defmodule Researcher do
  use Omni.Agent

  @impl Omni.Agent
  def init(state) do
    {:ok, %{state |
      system: "Research using your tools, then call task_complete.",
      tools: [SearchTool.new(), FetchTool.new(), completion_tool()]
    }}
  end

  @impl Omni.Agent
  def handle_turn(response, state) do
    if calls_completion?(response) do
      {:stop, state}
    else
      {:continue, "Keep going. Call task_complete when done.", state}
    end
  end

  defp completion_tool do
    Omni.tool(
      name: "task_complete",
      description: "Call when the task is fully complete.",
      input_schema: Omni.Schema.object(
        %{result: Omni.Schema.string(description: "Summary of what was accomplished")},
        required: [:result]
      ),
      handler: fn _input -> "OK" end
    )
  end

  defp calls_completion?(response) do
    Enum.any?(response.messages, fn message ->
      Enum.any?(message.content, &match?(%Omni.Content.ToolUse{name: "task_complete"}, &1))
    end)
  end
end
```

## Sessions

A session wraps an agent with conversation identity, a branching message
tree, and pluggable storage. Every turn is committed to the tree and
persisted through a store adapter. Reopening by id restores everything.

### Start and persist

```elixir
store = {Omni.Session.Store.FileSystem, base_path: "priv/sessions"}

{:ok, session} = Omni.Session.start_link(
  agent: [model: {:anthropic, "claude-sonnet-4-6"}],
  store: store,
  subscribe: true
)

:ok = Omni.Session.prompt(session, "Name three mountains.")
```

Session events mirror the agent's, re-tagged as `{:session, pid, ...}`,
plus tree and store events:

```elixir
{:session, ^session, :text_delta, %{delta: text}}
{:session, ^session, :turn,       {:stop, response}}
{:session, ^session, :tree,       %{tree: tree, new_nodes: ids}}
{:session, ^session, :store,      {:saved, :tree}}
```

### Resume later

```elixir
id = Omni.Session.get_snapshot(session).id
Omni.Session.stop(session)

# Later, in a new process or after a restart:
{:ok, session} = Omni.Session.start_link(
  load: id,
  agent: [model: {:anthropic, "claude-sonnet-4-6"}],
  store: store
)
```

On load, persisted model, system prompt, opts, title, and the full
message tree are restored. Tools are supplied fresh each boot — function
refs aren't persisted.

### Branching and navigation

The message tree supports multiple children per node. Three operations
cover the common edit-and-regenerate UX:

```elixir
# Regenerate the reply to a user message — fresh assistant response for
# the same prompt:
Omni.Session.branch(session, user_node_id)

# Edit the next user message — new user + new turn as a child of the
# target assistant:
Omni.Session.branch(session, assistant_node_id, "Try it this way instead.")

# Switch between existing branches by moving the active path:
Omni.Session.navigate(session, node_id)
```

All three are idle-only. Use `Omni.Session.get_tree/1` to inspect the
tree, and `Omni.Session.Tree.children/2` / `siblings/2` to find
alternatives at any node.

## Multi-session apps

For apps that manage many concurrent conversations, `use
Omni.Session.Manager` in your own module and drop it into your
supervision tree:

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

Manage sessions by id:

```elixir
# Start fresh — auto-generated id, caller auto-subscribed as controller
{:ok, pid} = MyApp.Sessions.create(
  agent: [model: {:anthropic, "claude-sonnet-4-6"}]
)

# Load existing session
{:ok, _, pid}  = MyApp.Sessions.open("abc-123")

# Stop the process, keep the store
:ok = MyApp.Sessions.close("abc-123")

# Stop the process and delete the store entry
:ok = MyApp.Sessions.delete("abc-123")

# Index views
{:ok, summaries} = MyApp.Sessions.list(limit: 50)   # store-backed
running          = MyApp.Sessions.list_running()    # in-memory projection
```

Subscribe to a live cross-session feed for dashboards and session lists:

```elixir
{:ok, running} = MyApp.Sessions.subscribe()

receive do
  {:manager, MyApp.Sessions, :session_added,   %{id: id, title: t, status: s}} -> ...
  {:manager, MyApp.Sessions, :session_status,  %{id: id, status: s}}           -> ...
  {:manager, MyApp.Sessions, :session_title,   %{id: id, title: t}}            -> ...
  {:manager, MyApp.Sessions, :session_removed, %{id: id}}                      -> ...
end
```

## LiveView

Session events map cleanly to `handle_info/2`. `open/3` auto-subscribes
the caller as a controller, so the LiveView receives `{:session, ...}`
events without an explicit subscribe call:

```elixir
def mount(%{"id" => id}, _params, socket) do
  {:ok, _, pid} = MyApp.Sessions.open(id)
  snapshot = Omni.Session.get_snapshot(pid)

  {:ok, assign(socket,
    session: pid,
    messages: Omni.Session.Tree.messages(snapshot.tree)
  )}
end

def handle_event("submit", %{"prompt" => text}, socket) do
  :ok = Omni.Session.prompt(socket.assigns.session, text)
  {:noreply, socket}
end

def handle_info({:session, _pid, :text_delta, %{delta: text}}, socket) do
  {:noreply, handle_streaming_text(socket, text)}
end

def handle_info({:session, _pid, :turn, {_, response}}, socket) do
  {:noreply, handle_new_messages(socket, response.messages)}
end
```

## Documentation

Full API reference is available on [HexDocs](https://hexdocs.pm/omni_agent).

## License

This package is open source and released under the [Apache-2 License](https://github.com/aaronrussell/omni_agent/blob/main/LICENSE).

© Copyright 2026 [Push Code Ltd](https://www.pushcode.com/).
