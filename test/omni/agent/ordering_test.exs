defmodule Omni.Agent.OrderingTest do
  use Omni.Agent.AgentCase, async: true

  @multi_tool_use_fixture "test/support/fixtures/synthetic/anthropic_multi_tool_use.sse"

  defmodule MultiResultAgent do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(tool_use, state) do
      result =
        Omni.Content.ToolResult.new(
          tool_use_id: tool_use.id,
          name: tool_use.name,
          content: "provided-for-#{tool_use.id}"
        )

      {:result, result, state}
    end
  end

  defmodule MixedDecisionAgent do
    use Omni.Agent

    # First tool_use is provided, second is rejected — exercises interleaving
    # across the rejected_results and provided_results accumulators.
    @impl Omni.Agent
    def handle_tool_use(%{id: "toolu_AAA_first"} = tool_use, state) do
      result =
        Omni.Content.ToolResult.new(
          tool_use_id: tool_use.id,
          name: tool_use.name,
          content: "provided-for-#{tool_use.id}"
        )

      {:result, result, state}
    end

    def handle_tool_use(_tool_use, state) do
      {:reject, "denied", state}
    end
  end

  describe "multiple {:result, _} decisions" do
    test "tool-result user message preserves tool_use order" do
      {:ok, agent} =
        start_agent_with_module(MultiResultAgent,
          tools: [tool_with_handler()],
          fixtures: [@multi_tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Weather in London and Paris?")
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      # Locate the user message carrying tool_result blocks.
      messages = Agent.get_state(agent, :messages)

      tool_result_msg =
        Enum.find(messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      assert tool_result_msg,
             "expected a user message carrying tool_result blocks, got: #{inspect(messages)}"

      ids_in_order = Enum.map(tool_result_msg.content, & &1.tool_use_id)

      assert ids_in_order == ["toolu_AAA_first", "toolu_BBB_second"],
             "tool_result blocks should follow the order of the tool_use blocks in the assistant message, got #{inspect(ids_in_order)}"
    end
  end

  describe "mixed :reject / :result decisions" do
    test "tool-result user message preserves tool_use order across decision types" do
      {:ok, agent} =
        start_agent_with_module(MixedDecisionAgent,
          tools: [tool_with_handler()],
          fixtures: [@multi_tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Weather in London and Paris?")
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      messages = Agent.get_state(agent, :messages)

      tool_result_msg =
        Enum.find(messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      assert tool_result_msg

      ids_in_order = Enum.map(tool_result_msg.content, & &1.tool_use_id)

      assert ids_in_order == ["toolu_AAA_first", "toolu_BBB_second"],
             "tool_result blocks should follow the order of the tool_use blocks even when decisions mix :reject and :result, got #{inspect(ids_in_order)}"
    end
  end

  describe ":turn response fields across segments" do
    # Finding #2: commit_segment does not clear last_response. build_turn_response
    # reads last_response for :stop_reason and :output. In normal flow
    # handle_step_complete always overwrites last_response before finalize_turn
    # fires, so this test is expected to pass — its purpose is to pin down that
    # invariant so a future regression (e.g. a new code path that calls
    # finalize_turn without a fresh step) would surface here.
    test "each :turn response's stop_reason matches that segment's last :step stop_reason" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      # Split events into segments, each terminated by a :turn event.
      # For each segment, compare the last :step's stop_reason with the :turn's.
      {segments, _} =
        Enum.reduce(events, {[], []}, fn
          {:turn, {_kind, response}}, {done, acc} ->
            {[{Enum.reverse(acc), response} | done], []}

          event, {done, acc} ->
            {done, [event | acc]}
        end)

      segments = Enum.reverse(segments)
      assert length(segments) == 3

      for {segment_events, turn_response} <- segments do
        step_events = for {:step, step_resp} <- segment_events, do: step_resp
        assert step_events != [], "segment had no :step events: #{inspect(segment_events)}"
        last_step = List.last(step_events)

        assert turn_response.stop_reason == last_step.stop_reason,
               "segment's :turn stop_reason (#{inspect(turn_response.stop_reason)}) must match its last :step stop_reason (#{inspect(last_step.stop_reason)})"
      end
    end
  end
end
