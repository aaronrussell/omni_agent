defmodule Omni.Agent.StatusEventTest do
  use Omni.Agent.AgentCase, async: true

  describe ":status event — transitions" do
    test "fires :busy when a turn starts and :idle when it stops" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      statuses = for {:status, s} <- events, do: s
      assert statuses == [:busy, :idle]
    end

    test ":status :busy precedes the :message user event at turn start" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      shape =
        events
        |> Enum.map(fn
          {:status, s} -> {:status, s}
          {:message, _} -> :message
          {:step, _} -> :step
          {:turn, _} -> :turn
          {type, _} -> type
        end)
        |> Enum.filter(&(&1 in [:message, :step, :turn] or match?({:status, _}, &1)))

      assert shape == [
               {:status, :busy},
               :message,
               :message,
               :step,
               {:status, :idle},
               :turn
             ]
    end

    test ":status :idle precedes :turn {:stop, _}" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")

      assert_receive {:agent, ^agent, :status, :idle}, 1000
      assert_receive {:agent, ^agent, :turn, {:stop, _}}, 1000
    end

    test "fires :idle on cancel during a busy turn" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 500)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive {:agent, ^agent, :status, :busy}, 500
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      assert_receive {:agent, ^agent, :status, :idle}, 1000
      assert_receive {:agent, ^agent, :cancelled, _}, 1000
    end

    test ":status :idle precedes :cancelled" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 500)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert trace_statuses_and_terminal(events, :cancelled) == [:busy, :idle, :cancelled]
    end

    test "fires :idle on error after handle_error/2 returns {:stop, _}" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert trace_statuses_and_terminal(events, :error) == [:busy, :idle, :error]
    end

    test "fires :paused when handle_tool_use returns {:pause, _, _}" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")

      # Collect until :pause terminates collect_events.
      events = collect_events(agent)
      assert trace_statuses_and_terminal(events, :pause) == [:busy, :paused, :pause]
    end

    test "fires :busy on resume from paused, then :idle on turn end" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      assert_receive {:agent, ^agent, :status, :busy}, 1000
      assert_receive {:agent, ^agent, :status, :paused}, 1000
      assert_receive {:agent, ^agent, :pause, _}, 1000

      :ok = Agent.resume(agent, :execute)

      assert_receive {:agent, ^agent, :status, :busy}, 1000
      assert_receive {:agent, ^agent, :status, :idle}, 2000
      assert_receive {:agent, ^agent, :turn, {:stop, _}}, 1000
    end

    test "fires :idle when cancelling from the paused state" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      assert_receive {:agent, ^agent, :status, :paused}, 2000
      assert_receive {:agent, ^agent, :pause, _}, 1000

      :ok = Agent.cancel(agent)

      assert_receive {:agent, ^agent, :status, :idle}, 1000
      assert_receive {:agent, ^agent, :cancelled, _}, 1000
    end

    test "does not emit :status when reset_turn runs from idle (no transition)" do
      {:ok, agent} = start_agent()
      # Subscribe the test process (default) and wait for a finished turn to settle.
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      # Attempt to cancel while idle — should error, no :status event should fire.
      assert {:error, :idle} = Agent.cancel(agent)
      refute_receive {:agent, ^agent, :status, _}, 100
    end
  end

  # Returns a flat list of status payloads and the terminal event tag in
  # the order they appear — e.g. [:busy, :idle, :error].
  defp trace_statuses_and_terminal(events, terminal) do
    Enum.flat_map(events, fn
      {:status, s} -> [s]
      {^terminal, _} -> [terminal]
      _ -> []
    end)
  end
end
