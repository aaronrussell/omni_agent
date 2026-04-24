defmodule Omni.Agent.ContinuationTest do
  use Omni.Agent.AgentCase, async: true

  describe "continuation" do
    test "{:continue, prompt, state} loops for 3 turns" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      # Should have exactly 2 :turn {:continue, _} events and 1 :turn {:stop, _}
      continue_events = for {:turn, {:continue, _data}} <- events, do: :ok
      stop_events = for {:turn, {:stop, _data}} <- events, do: :ok
      assert length(continue_events) == 2
      assert length(stop_events) == 1

      assert {:turn, {:stop, %Response{}}} = List.last(events)
      assert Agent.get_state(agent, :private).turn_count == 3
    end

    test "context accumulates all messages across turns" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      _events = collect_events(agent)

      messages = Agent.get_state(agent, :messages)
      # Initial user + assistant, then 2 more (user continue + assistant) per extra turn
      # = 2 + 2 + 2 = 6 messages
      assert length(messages) == 6
    end
  end

  describe "max_steps" do
    test "limits steps even though ContinueAgent wants to continue" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start", max_steps: 2)
      events = collect_events(agent)

      # Should stop after 2 steps
      assert {:turn, {:stop, %Response{}}} = List.last(events)

      # Only 1 :turn {:continue, _} event (step 1 completes, continues, step 2 completes, forced stop)
      continue_events = for {:turn, {:continue, _data}} <- events, do: :ok
      assert length(continue_events) == 1
    end

    test "max_steps hit mid-tool-loop forces stop" do
      {:ok, agent} =
        start_agent_with_module(CustomTurn,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @tool_use_fixture]
        )

      :ok = Agent.prompt(agent, "Use tool twice", max_steps: 2)
      events = collect_events(agent)

      # Should stop with :turn {:stop, _} (max_steps hit after tool results processed)
      assert {:turn, {:stop, %Response{stop_reason: :tool_use}}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle

      # Context should be committed (includes tool result messages)
      messages = Agent.get_state(agent, :messages)
      assert length(messages) > 0
    end
  end

  describe "usage in response" do
    test "each :turn event's usage reflects only its own turn, not the cumulative across continuations" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      turn_usages =
        for {:turn, {_kind, %Response{usage: usage}}} <- events, do: usage.total_tokens

      assert length(turn_usages) == 3
      # All three turns use the same fixture, so per-turn usage must be
      # equal. If turn_usage failed to reset between turns the values
      # would be X, 2X, 3X — non-equal and accumulating.
      assert Enum.uniq(turn_usages) |> length() == 1
      assert hd(turn_usages) > 0
    end
  end

  describe "continue event content" do
    test ":turn {:continue, _} carries the turn's response with messages" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      continue_events = for {:turn, {:continue, data}} <- events, do: data
      assert length(continue_events) == 2

      # First continue should carry this turn's 2 messages (user + assistant)
      [first_continue | _] = continue_events
      assert %Response{} = first_continue
      assert length(first_continue.messages) == 2
    end
  end

  describe "per-prompt opts" do
    test "per-prompt opts are ephemeral and don't persist to next turn" do
      {:ok, agent} =
        start_agent(fixtures: [@text_fixture, @text_fixture])

      # First prompt with max_steps override
      :ok = Agent.prompt(agent, "First", max_steps: 1)
      _events = collect_events(agent)

      # Second prompt without opts — should use agent defaults (no max_steps limit)
      # If per-prompt opts persisted, this would be limited to 1 step
      :ok = Agent.prompt(agent, "Second")
      events = collect_events(agent)

      assert {:turn, {:stop, %Response{}}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
    end
  end
end
