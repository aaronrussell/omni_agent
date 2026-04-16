defmodule Omni.Agent.PauseResumeTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Tree

  describe "pause/resume" do
    test "{:pause, reason, state} from handle_tool_use pauses agent" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)

      # Should end with :pause and a ToolUse
      assert {:pause, {:authorize, %ToolUse{name: "get_weather"}}} = List.last(events)
      assert Agent.get_state(agent, :status) == :paused

      # Clean up
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)
      Agent.resume(agent, :execute)
      _events = collect_events(agent)
    end

    test "resume(:execute) executes tool and continues to :done" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      :ok = Agent.resume(agent, :execute)
      events = collect_events(agent)

      # Should have tool_result and then :stop
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert length(tool_results) > 0
      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
    end

    test "turn cursor survives pause/resume — :stop response includes the original prompt" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      :ok = Agent.resume(agent, :execute)
      events = collect_events(agent)

      assert {:stop, %Response{messages: messages}} = List.last(events)

      # The turn slice must include the original user prompt pushed before pause
      # as well as everything produced after resume — proving the turn_start
      # cursor was preserved across pause.
      [first | _] = messages
      assert first.role == :user

      # Full turn: user prompt → assistant with tool_use → user tool_result → assistant text
      assert length(messages) == 4
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
    end

    test "resume({:reject, reason}) produces error ToolResult and continues" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      :ok = Agent.resume(agent, {:reject, "not safe"})
      events = collect_events(agent)

      # Should have tool_result with is_error and then :stop
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)
      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
    end

    test "resume when not paused returns {:error, :not_paused}" do
      {:ok, agent} = start_agent()
      assert {:error, :not_paused} = Agent.resume(agent, :execute)
    end

    test "cancel while paused resets state" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      :ok = Agent.cancel(agent)
      events = collect_events(agent, 2000)
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # Cancel rewinds the active path; abandoned nodes stay in the tree
      assert Tree.messages(Agent.get_state(agent, :tree)) == []
    end

    test "multiple tools: pause on first, approve, remaining processed normally" do
      # This test uses a module that only pauses on "get_weather" but auto-approves others
      # The fixture has one tool_use (get_weather) so after approval it should proceed normally
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{name: "get_weather"}}} = List.last(events)

      :ok = Agent.resume(agent, :execute)
      events = collect_events(agent)

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
    end
  end

  describe "resume({:result, result})" do
    test "provides result directly and continues loop" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      result =
        ToolResult.new(
          tool_use_id: "toolu_test",
          name: "get_weather",
          content: "Manual: 72F"
        )

      :ok = Agent.resume(agent, {:result, result})
      events = collect_events(agent)

      tool_results = for {:tool_result, data} <- events, do: data
      assert length(tool_results) > 0
      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
    end
  end
end
