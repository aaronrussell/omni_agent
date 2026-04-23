defmodule Omni.Agent.OrderingTest do
  use Omni.Agent.AgentCase, async: true

  @multi_tool_use_fixture "test/support/fixtures/synthetic/anthropic_multi_tool_use.sse"
  @three_tool_use_fixture "test/support/fixtures/synthetic/anthropic_three_tool_use.sse"

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
    # across decision types in the final tool-result user message.
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

  defmodule ThreeWayAgent do
    use Omni.Agent

    # First → :execute (slow handler), middle → :reject, last → :execute (fast).
    # Exercises the executor returning completion-ordered results while the
    # final message must still follow tool-use order.
    @impl Omni.Agent
    def handle_tool_use(%{id: "toolu_AAA_first"}, state), do: {:execute, state}

    def handle_tool_use(%{id: "toolu_BBB_middle"}, state),
      do: {:reject, "denied", state}

    def handle_tool_use(%{id: "toolu_CCC_last"}, state), do: {:execute, state}
  end

  defmodule PauseMiddleAgent do
    use Omni.Agent

    # First → :execute, middle → :pause (resumed with {:result, _} by test),
    # last → :execute. Verifies a resumed decision lands at its original
    # tool-use index, not at the end.
    @impl Omni.Agent
    def handle_tool_use(%{id: "toolu_BBB_middle"}, state),
      do: {:pause, :authorize, state}

    def handle_tool_use(_tool_use, state), do: {:execute, state}
  end

  defmodule AllExecuteAgent do
    use Omni.Agent

    @impl Omni.Agent
    def handle_tool_use(_tool_use, state), do: {:execute, state}
  end

  # get_weather handler that sleeps for "London" so the first tool_use in the
  # 2-tool fixture completes *after* the second. Lets tests prove output order
  # ignores executor completion order.
  defp timed_weather_tool do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
      handler: fn input ->
        if input["location"] == "London", do: Process.sleep(100)
        "#{input["location"]}: 72F"
      end
    )
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

  describe "three tool uses with mixed :execute / :reject / :execute" do
    test "tool-result order follows tool_use order, not executor completion order" do
      {:ok, agent} =
        start_agent_with_module(ThreeWayAgent,
          tools: [timed_weather_tool()],
          fixtures: [@three_tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Weather in London, Paris, Berlin?")
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      messages = Agent.get_state(agent, :messages)

      tool_result_msg =
        Enum.find(messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      ids_in_order = Enum.map(tool_result_msg.content, & &1.tool_use_id)

      assert ids_in_order == ["toolu_AAA_first", "toolu_BBB_middle", "toolu_CCC_last"],
             "tool_result blocks must follow tool_use order even when the executor returns results in completion order, got #{inspect(ids_in_order)}"

      # Sanity: the middle one is the rejection, and the first/last carry
      # executed output — proves we're actually interleaving decision types.
      [first, middle, last] = tool_result_msg.content
      refute first.is_error
      assert middle.is_error
      refute last.is_error
    end
  end

  describe "pause/resume on middle tool_use" do
    test ":result decision on resume lands at its original tool-use index" do
      {:ok, agent} =
        start_agent_with_module(PauseMiddleAgent,
          tools: [tool_with_handler()],
          fixtures: [@three_tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Weather in London, Paris, Berlin?")
      events = collect_events(agent)

      assert {:pause, {:authorize, %ToolUse{id: "toolu_BBB_middle"}}} = List.last(events)

      provided =
        ToolResult.new(
          tool_use_id: "toolu_BBB_middle",
          name: "get_weather",
          content: "provided-on-resume"
        )

      :ok = Agent.resume(agent, {:result, provided})
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      messages = Agent.get_state(agent, :messages)

      tool_result_msg =
        Enum.find(messages, fn msg ->
          msg.role == :user and Enum.any?(msg.content, &match?(%ToolResult{}, &1))
        end)

      ids_in_order = Enum.map(tool_result_msg.content, & &1.tool_use_id)

      assert ids_in_order == ["toolu_AAA_first", "toolu_BBB_middle", "toolu_CCC_last"],
             "the resumed decision must land at its original tool_use index, got #{inspect(ids_in_order)}"

      middle_result = Enum.at(tool_result_msg.content, 1)
      assert Enum.any?(middle_result.content, &match?(%Text{text: "provided-on-resume"}, &1))
    end
  end

  describe "two parallel executes with asymmetric handler timing" do
    test "output order follows tool_use order, not handler completion order" do
      {:ok, agent} =
        start_agent_with_module(AllExecuteAgent,
          tools: [timed_weather_tool()],
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

      ids_in_order = Enum.map(tool_result_msg.content, & &1.tool_use_id)

      assert ids_in_order == ["toolu_AAA_first", "toolu_BBB_second"],
             "tool_result order must follow tool_use order even when the first handler is slower than the second, got #{inspect(ids_in_order)}"
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
