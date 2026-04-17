defmodule Omni.Agent.TestAgents do
  @moduledoc false

  defmodule WithInit do
    use Omni.Agent

    @impl Omni.Agent
    def init(state) do
      name = state.private[:agent_name] || "default"
      {:ok, %{state | private: Map.put(state.private, :name, name)}}
    end
  end

  defmodule FailInit do
    use Omni.Agent

    @impl Omni.Agent
    def init(_state), do: {:error, :bad_config}
  end

  defmodule CustomTurn do
    use Omni.Agent

    @impl Omni.Agent
    def handle_turn(response, state) do
      {:stop, %{state | private: Map.put(state.private, :last_stop_reason, response.stop_reason)}}
    end
  end

  defmodule RejectTool do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(%{name: "get_weather"} = _tool_use, state) do
      {:reject, "not allowed", state}
    end

    def handle_tool_use(_tool_use, state), do: {:execute, state}
  end

  defmodule ModifyResult do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_result(result, state) do
      modified = %{result | content: [Omni.Content.Text.new("modified output")]}
      {:ok, modified, state}
    end
  end

  defmodule TrackToolUses do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(tool_use, state) do
      calls = Map.get(state.private, :tool_calls, [])
      state = %{state | private: Map.put(state.private, :tool_calls, calls ++ [tool_use.name])}
      {:execute, state}
    end
  end

  defmodule ContinueAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(state) do
      {:ok, %{state | private: Map.put(state.private, :turn_count, 0)}}
    end

    @impl Omni.Agent
    def handle_turn(_response, state) do
      count = state.private.turn_count + 1
      state = %{state | private: %{state.private | turn_count: count}}

      if count < 3 do
        {:continue, "Continue.", state}
      else
        {:stop, state}
      end
    end
  end

  defmodule ErrorRetryAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(state) do
      {:ok, %{state | private: Map.put(state.private, :retries, 0)}}
    end

    @impl Omni.Agent
    def handle_error(_error, state) do
      retries = state.private.retries

      if retries < 1 do
        state = %{state | private: %{state.private | retries: retries + 1}}
        {:retry, state}
      else
        {:stop, state}
      end
    end
  end

  defmodule TerminateAgent do
    use Omni.Agent

    @impl Omni.Agent
    def terminate(reason, state) do
      if pid = state.private[:test_pid] do
        send(pid, {:terminated, reason})
      end
    end
  end

  defmodule CrashRetryAgent do
    use Omni.Agent

    @impl Omni.Agent
    def init(state) do
      {:ok, %{state | private: Map.put(state.private, :retries, 0)}}
    end

    @impl Omni.Agent
    def handle_error({:step_crashed, _} = _error, state) do
      retries = state.private.retries

      if retries < 1 do
        {:retry, %{state | private: %{state.private | retries: retries + 1}}}
      else
        {:stop, state}
      end
    end

    def handle_error(_error, state), do: {:stop, state}
  end

  defmodule PauseAgent do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(%{name: "get_weather"} = _tool_use, state) do
      {:pause, :authorize, state}
    end

    def handle_tool_use(_tool_use, state), do: {:execute, state}
  end

  defmodule ResultAgent do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(%{name: "get_weather"} = tool_use, state) do
      result =
        Omni.Content.ToolResult.new(
          tool_use_id: tool_use.id,
          name: tool_use.name,
          content: "Provided: 72F and sunny"
        )

      {:result, result, state}
    end

    def handle_tool_use(_tool_use, state), do: {:execute, state}
  end
end
