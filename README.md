# OmniAgent

**Stateful LLM agents for Elixir.**
Multi-turn conversations with lifecycle callbacks, tool approval, and steering.
*Built on [Omni](https://github.com/aaronrussell/omni)*.

## Features

- **Supervised process** — a GenServer that owns the conversation, so callers don't thread state
- **Lifecycle callbacks** — control continuation, tool approval, error handling, and cleanup
- **Tool approval** — pause on any tool use, inspect it, approve or reject, then resume
- **Prompt steering** — send a new prompt while running to redirect the agent at the next turn boundary
- **Streaming events** — text deltas, tool results, and lifecycle events delivered as process messages

## Installation

Add OmniAgent to your dependencies:

```elixir
def deps do
  [
    {:omni_agent, "~> 0.1"}
  ]
end
```

OmniAgent depends on `omni`, which provides the LLM API layer. Configure your
provider API keys as described in the [Omni README](https://github.com/aaronrussell/omni#installation).

## Quick start

### Simple conversation

Start an agent and send a prompt — events arrive as process messages:

```elixir
{:ok, agent} = Omni.Agent.start_link(model: {:anthropic, "claude-sonnet-4-5-20250514"})
:ok = Omni.Agent.prompt(agent, "Hello!")

receive do
  {:agent, ^agent, :text_delta, %{delta: text}} -> IO.write(text)
  {:agent, ^agent, :done, response} -> IO.puts("\nDone!")
end
```

### Custom agent with callbacks

Define a module with `use Omni.Agent` to customize behaviour. All callbacks are
optional with sensible defaults:

```elixir
defmodule MyAgent do
  use Omni.Agent

  @impl Omni.Agent
  def init(opts) do
    {:ok, %{user: opts[:user]}}
  end

  @impl Omni.Agent
  def handle_turn(%{stop_reason: :length}, state) do
    {:continue, "Continue where you left off.", state}
  end

  def handle_turn(_response, state) do
    {:stop, state}
  end
end

{:ok, agent} = MyAgent.start_link(
  model: {:anthropic, "claude-sonnet-4-5-20250514"},
  system: "You are a helpful assistant.",
  user: :current_user
)
```

Override `start_link/1` to bake in defaults — standard GenServer pattern:

```elixir
defmodule ResearchAgent do
  use Omni.Agent

  def start_link(opts \\ []) do
    defaults = [
      model: {:anthropic, "claude-sonnet-4-5-20250514"},
      system: "You are a research assistant.",
      tools: [SearchTool.new(), FetchTool.new()]
    ]
    super(Keyword.merge(defaults, opts))
  end

  @impl Omni.Agent
  def handle_turn(%{stop_reason: :stop}, state) do
    {:continue, "Continue working. Call task_complete when finished.", state}
  end

  def handle_turn(_response, state), do: {:stop, state}
end
```

### Tool approval

Control which tools execute with `handle_tool_use/2`. Pause for human approval,
reject, or provide results directly:

```elixir
defmodule SafeAgent do
  use Omni.Agent

  @impl Omni.Agent
  def handle_tool_use(%{name: "delete_" <> _} = tool_use, state) do
    {:pause, :requires_approval, state}
  end

  def handle_tool_use(_tool_use, state) do
    {:execute, state}
  end
end

# The listener receives {:agent, pid, :pause, {:requires_approval, %ToolUse{}}}
# Then the caller decides:
Omni.Agent.resume(agent, :execute)            # approve
Omni.Agent.resume(agent, {:reject, "Denied"}) # reject
```

### Autonomous agents

The difference between a chatbot and an autonomous agent is entirely in the
callbacks. Define a completion tool and loop until the model calls it:

```elixir
defmodule ResearchAgent do
  use Omni.Agent

  def start_link(opts \\ []) do
    defaults = [
      model: {:anthropic, "claude-sonnet-4-5-20250514"},
      system: "You are a research assistant. Use your tools to research, " <>
              "then call task_complete with your findings.",
      tools: [SearchTool.new(), FetchTool.new(), task_complete()]
    ]
    super(Keyword.merge(defaults, opts))
  end

  @impl Omni.Agent
  def handle_turn(%{stop_reason: :length}, state) do
    {:continue, "Continue where you left off.", state}
  end

  def handle_turn(response, state) do
    if completion_tool_called?(response) do
      {:stop, state}
    else
      {:continue, "Continue working. Call task_complete when finished.", state}
    end
  end

  defp task_complete do
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

  defp completion_tool_called?(response) do
    Enum.any?(response.messages, fn message ->
      Enum.any?(message.content, fn
        %Omni.Content.ToolUse{name: "task_complete"} -> true
        _ -> false
      end)
    end)
  end
end
```

### LiveView integration

Agent events map naturally to `handle_info/2`:

```elixir
def handle_event("submit", %{"prompt" => text}, socket) do
  :ok = Omni.Agent.prompt(socket.assigns.agent, text)
  {:noreply, socket}
end

def handle_info({:agent, _pid, :text_delta, %{delta: text}}, socket) do
  {:noreply, stream_insert(socket, :chunks, %{text: text})}
end

def handle_info({:agent, _pid, :done, _response}, socket) do
  {:noreply, assign(socket, :status, :complete)}
end
```

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/omni_agent).

## License

This package is open source and released under the [Apache-2 License](https://github.com/aaronrussell/omni_agent/blob/main/LICENSE).

© Copyright 2024-2026 [Push Code Ltd](https://www.pushcode.com/).
