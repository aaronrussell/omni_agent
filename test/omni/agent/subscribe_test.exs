defmodule Omni.Agent.SubscribeTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.{Snapshot, Tree}

  describe "subscribe/1 basics" do
    test "returns {:ok, %Snapshot{}} with agent's current state" do
      {:ok, agent} = start_agent(subscribe: false)

      assert {:ok, %Snapshot{} = snap} = Agent.subscribe(agent)
      assert snap.status == :idle
      assert snap.step == 0
      assert snap.tree == %Tree{}
      assert snap.tools == []
      assert snap.system == nil
      assert snap.id == nil
      assert snap.partial_message == nil
      assert snap.paused == nil
      assert %Omni.Model{} = snap.model
    end

    test "snapshot carries configured system, tools and meta" do
      tool = tool_with_handler()

      {:ok, agent} =
        start_agent(
          system: "Be concise.",
          tools: [tool],
          meta: %{title: "Test"},
          subscribe: false
        )

      assert {:ok, snap} = Agent.subscribe(agent)
      assert snap.system == "Be concise."
      assert [^tool] = snap.tools
      assert snap.meta == %{title: "Test"}
    end

    test "snapshot carries committed tree after a turn" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      # start_agent already subscribed us; a second subscribe yields a fresh snapshot
      assert {:ok, snap} = Agent.subscribe(agent)
      assert Tree.size(snap.tree) == 2
    end

    test "subscribing the same pid twice is idempotent (no duplicate events)" do
      {:ok, agent} = start_agent()
      # start_agent already subscribed self(). Subscribe again:
      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # Count :stop events — should be 1, not 2
      stop_events = for {:stop, _} <- events, do: :ok
      assert length(stop_events) == 1
    end
  end

  describe "unsubscribe/1" do
    test "stops the caller from receiving subsequent events" do
      {:ok, agent} = start_agent()

      :ok = Agent.unsubscribe(agent)
      :ok = Agent.prompt(agent, "Hello!")

      # Wait for the turn to complete without receiving anything
      Process.sleep(300)
      assert Agent.get_state(agent, :status) == :idle

      refute_received {:agent, ^agent, _, _}
    end

    test "is idempotent (unsubscribing non-subscriber is :ok)" do
      {:ok, agent} = start_agent(subscribe: false)
      assert :ok = Agent.unsubscribe(agent)
      assert :ok = Agent.unsubscribe(agent)
    end
  end

  describe "multi-subscriber broadcast" do
    test "all subscribers receive the same events" do
      {:ok, agent} = start_agent(subscribe: false)
      test_pid = self()

      # Spawn two extra subscribers that mirror their events back to the test pid
      relay = fn tag ->
        fn ->
          {:ok, _} = Agent.subscribe(agent)
          send(test_pid, {:subscribed, tag})

          receive do
            {:agent, ^agent, :stop, _} = msg ->
              send(test_pid, {tag, msg})
          after
            5_000 -> send(test_pid, {tag, :timeout})
          end
        end
      end

      spawn_link(relay.(:a))
      spawn_link(relay.(:b))

      assert_receive {:subscribed, :a}, 1_000
      assert_receive {:subscribed, :b}, 1_000

      :ok = Agent.prompt(agent, "Hello!")

      assert_receive {:a, {:agent, ^agent, :stop, _}}, 5_000
      assert_receive {:b, {:agent, ^agent, :stop, _}}, 5_000
    end

    test "crashed subscribers are reaped and don't block broadcasts" do
      {:ok, agent} = start_agent()

      # Subscribe a process that dies immediately.
      {:ok, dying} =
        Task.start_link(fn ->
          {:ok, _} = Agent.subscribe(agent)
          # Exit normally after subscribing — the agent's monitor should
          # reap this subscriber from the set.
          :ok
        end)

      # Wait for the dying task to complete + DOWN to arrive at agent
      ref = Process.monitor(dying)
      assert_receive {:DOWN, ^ref, :process, ^dying, _}, 1_000
      # Give the agent a moment to process the DOWN message
      Process.sleep(50)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # The test pid (still subscribed) gets :stop; the dead subscriber caused no crash
      assert {:stop, _} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
    end
  end

  describe "mid-stream catchup" do
    test "late subscriber snapshots a running agent and still receives subsequent events" do
      # stub_slow delays the entire response by `delay` ms. Sleep less than
      # that so the agent is still waiting for the upstream when we subscribe.
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 500)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      # Let the request spawn the step task, but return before the upstream
      # response starts arriving.
      Process.sleep(100)

      {:ok, snap} = Agent.subscribe(agent)
      assert snap.status == :running

      events = collect_events(agent)
      assert {:stop, _} = List.last(events)

      # Subsequent streaming events must reach the late subscriber — proves the
      # subscribe `handle_call` atomically captured the snapshot AND registered
      # this pid before any further events were broadcast.
      deltas = for {:text_delta, _} <- events, do: :ok
      assert length(deltas) > 0
    end
  end

  describe "pause catchup" do
    test "snapshot carries :paused info for late joiners" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)
      assert Agent.get_state(agent, :status) == :paused

      # A new subscriber joining now should see pause details in the snapshot.
      test_pid = self()

      spawn_link(fn ->
        {:ok, snap} = Agent.subscribe(agent)
        send(test_pid, {:late_snap, snap})
      end)

      assert_receive {:late_snap, snap}, 1_000
      assert snap.status == :paused
      assert {:authorize, %ToolUse{name: "get_weather"}} = snap.paused

      # Clean up
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe ":message event" do
    test "fires for the initial user prompt before any streaming events" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # The first event should be :message carrying the user message
      [{:message, %Omni.Message{role: :user}} | _] = events
    end

    test "fires for assistant message at step complete (before :step event)" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # Find indices of the first assistant :message and the first :step
      assistant_idx =
        Enum.find_index(events, fn
          {:message, %Omni.Message{role: :assistant}} -> true
          _ -> false
        end)

      step_idx = Enum.find_index(events, &match?({:step, _}, &1))

      assert is_integer(assistant_idx)
      assert is_integer(step_idx)
      assert assistant_idx < step_idx
    end

    test "fires for tool-result user message after executor completes" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      # Messages in order: user(prompt), assistant(tool_use), user(tool_result), assistant(text)
      message_events =
        for {:message, %Omni.Message{} = m} <- events, do: {m.role, has_tool_result?(m)}

      assert [
               {:user, false},
               {:assistant, _},
               {:user, true},
               {:assistant, _}
             ] = message_events
    end

    defp has_tool_result?(%Omni.Message{content: content}) do
      Enum.any?(content, &match?(%Omni.Content.ToolResult{}, &1))
    end
  end

  describe "partial_message lifecycle" do
    test "nil in the snapshot after a turn completes" do
      {:ok, agent} = start_agent(subscribe: false)

      :ok = Agent.prompt(agent, "Hello!")
      # Collect-and-discard to wait for turn completion
      {:ok, _snap} = Agent.subscribe(agent)
      _events = collect_events(agent)

      {:ok, snap} = Agent.subscribe(agent)
      assert snap.partial_message == nil
      assert snap.status == :idle
    end

    test "nil in the snapshot after cancel" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 500)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)
      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(100)
      :ok = Agent.cancel(agent)
      _events = collect_events(agent, 2000)

      {:ok, snap} = Agent.subscribe(agent)
      assert snap.partial_message == nil
      assert snap.status == :idle
    end
  end
end
