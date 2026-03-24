defmodule Omni.Agent.ToolTest do
  use Omni.Agent.AgentCase, async: true

  describe "tool use auto-loop" do
    test "executes tool and loops back to get final text response" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather in London?")
      events = collect_events(agent)

      # Should have tool_result events
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert length(tool_results) > 0

      # Should end with :done and a text response
      assert {:done, %Response{stop_reason: :stop} = resp} = List.last(events)
      assert [%Text{}] = resp.message.content

      # Context should have all messages: user, assistant(tool_use), user(tool_results), assistant(text)
      messages = Agent.get_state(agent, :context).messages
      assert length(messages) >= 4
    end
  end

  describe "handler-less tool" do
    test "does not loop, fires handle_turn with tool_use stop reason" do
      {:ok, agent} =
        start_agent_with_module(CustomTurn,
          tools: [tool_without_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # No tool_result events
      tool_results = for {:tool_result, _data} <- events, do: :ok
      assert tool_results == []

      # Should end with :done and tool_use stop reason
      assert {:done, %Response{stop_reason: :tool_use}} = List.last(events)
      assert Agent.get_state(agent, :private).last_stop_reason == :tool_use
    end
  end

  describe "handle_tool_use reject" do
    test "rejected tool produces error result, loop continues" do
      {:ok, agent} =
        start_agent_with_module(RejectTool,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Tool result event should have is_error: true
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)

      # Loop continues to final text response
      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end
  end

  describe "handle_tool_result modifies result" do
    test "modified result is used in the loop" do
      {:ok, agent} =
        start_agent_with_module(ModifyResult,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      assert {:done, %Response{}} = List.last(events)

      # The tool result user message should contain modified content
      messages = Agent.get_state(agent, :context).messages

      tool_result_msgs =
        Enum.filter(messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      assert length(tool_result_msgs) == 1
      [tr_msg] = tool_result_msgs
      [%ToolResult{} = tr] = tr_msg.content
      assert [%Text{text: "modified output"}] = tr.content
    end
  end

  describe "tool_result events emitted" do
    test "agent emits :tool_result events with expected data" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) == 1
      [tr] = tool_result_events
      assert tr.name == "get_weather"
      assert tr.is_error == false
    end
  end

  describe "cancel during tool execution" do
    test "cancels and discards pending messages" do
      slow_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input ->
            Process.sleep(5000)
            "result"
          end
        )

      {:ok, agent} =
        start_agent(
          tools: [slow_tool],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      # Wait for step to complete and executor to start
      Process.sleep(200)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # Cancel discards pending messages, context stays empty
      assert Agent.get_state(agent, :context).messages == []
    end
  end

  describe "tool timeout" do
    test "timed out tool produces error result, loop continues" do
      slow_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input ->
            Process.sleep(5000)
            "result"
          end
        )

      {:ok, agent} =
        start_agent(
          tools: [slow_tool],
          tool_timeout: 100,
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Tool result event should have is_error: true (timeout)
      tool_result_events = for {:tool_result, data} <- events, do: data
      assert length(tool_result_events) > 0
      assert Enum.any?(tool_result_events, & &1.is_error)

      # Loop continues to final response
      assert {:done, %Response{}} = List.last(events)
    end
  end

  describe "usage in response" do
    test "done response carries usage from tool loop steps" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      assert {:done, %Response{} = resp} = List.last(events)
      assert resp.usage.total_tokens > 0
      assert resp.usage.input_tokens > 0
      assert resp.usage.output_tokens > 0
    end
  end

  describe "handle_tool_use modifies private" do
    test "callback can store info in private" do
      {:ok, agent} =
        start_agent_with_module(TrackToolUses,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      _events = collect_events(agent)

      private = Agent.get_state(agent, :private)
      assert private.tool_calls == ["get_weather"]
    end
  end

  describe "handle_tool_use {:result, ...}" do
    test "provided result skips execution and continues loop" do
      {:ok, agent} =
        start_agent_with_module(ResultAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Should have tool_result (from provided result) and then :done
      tool_results = for {:tool_result, data} <- events, do: data
      assert length(tool_results) == 1
      [tr] = tool_results
      assert tr.name == "get_weather"
      refute tr.is_error

      assert {:done, %Response{stop_reason: :stop}} = List.last(events)
    end
  end
end
