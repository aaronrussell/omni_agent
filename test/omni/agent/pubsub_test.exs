defmodule Omni.Agent.PubSubTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Snapshot

  describe "subscribe/1" do
    test "caller receives agent events after subscribing" do
      {:ok, agent} = start_agent(subscribe: false)
      assert {:ok, %Snapshot{}} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:turn, {:stop, %Response{}}} = List.last(events)
    end

    test "returns a snapshot of the current state" do
      {:ok, agent} = start_agent(subscribe: false)
      assert {:ok, %Snapshot{state: state, pending: [], partial: nil}} = Agent.subscribe(agent)
      assert state.status == :idle
    end

    test "subscribing is idempotent — each event delivered exactly once" do
      {:ok, agent} = start_agent(subscribe: false)
      {:ok, _} = Agent.subscribe(agent)
      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # Only one :turn event was emitted; collect stops on :turn so if we
      # received a duplicate the second would still be in the mailbox.
      assert {:turn, {:stop, _}} = List.last(events)
      refute_receive {:agent, ^agent, :turn, _}, 100
    end
  end

  describe "subscribe/2" do
    test "subscribes the given pid instead of the caller" do
      {:ok, agent} = start_agent(subscribe: false)
      test_pid = self()

      helper =
        spawn_link(fn ->
          receive do
            {:agent, ^agent, :turn, {:stop, _}} = msg -> send(test_pid, {:helper_got, msg})
          after
            5000 -> send(test_pid, :helper_timeout)
          end
        end)

      {:ok, %Snapshot{}} = Agent.subscribe(agent, helper)

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive {:helper_got, {:agent, ^agent, :turn, {:stop, _}}}, 5000

      # Caller was not subscribed; nothing in our mailbox.
      refute_receive {:agent, ^agent, _, _}, 50
    end
  end

  describe "unsubscribe/1" do
    test "stops delivering events to the caller" do
      {:ok, agent} = start_agent()
      :ok = Agent.unsubscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      # Wait for the turn to complete on the server.
      Process.sleep(200)
      refute_receive {:agent, ^agent, _, _}, 50
    end

    test "unsubscribing when not subscribed is a no-op" do
      {:ok, agent} = start_agent(subscribe: false)
      assert :ok = Agent.unsubscribe(agent)
    end
  end

  describe "multi-subscriber delivery" do
    test "all subscribers receive identical event streams" do
      test_pid = self()

      helper =
        spawn_link(fn ->
          loop_forward(test_pid, :helper)
        end)

      {:ok, agent} = start_agent(subscribers: [self(), helper])

      :ok = Agent.prompt(agent, "Hello!")

      caller_events = collect_events(agent)
      helper_events = collect_forwarded(:helper, agent)

      assert {:turn, {:stop, _}} = List.last(caller_events)
      assert {:turn, {:stop, _}} = List.last(helper_events)

      # Same event types in the same order on both subscribers.
      caller_types = Enum.map(caller_events, &elem(&1, 0))
      helper_types = Enum.map(helper_events, &elem(&1, 0))
      assert caller_types == helper_types
    end
  end

  describe "subscriber death cleanup" do
    test "dying subscriber does not crash the agent; other subscribers still receive events" do
      {:ok, agent} = start_agent()

      dying =
        spawn(fn ->
          receive do
            :go -> :ok
          end
        end)

      {:ok, _} = Agent.subscribe(agent, dying)

      # Kill the helper and give the agent a beat to process :DOWN.
      Process.exit(dying, :kill)
      Process.sleep(50)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      # Agent is still alive.
      assert Process.alive?(agent)
    end
  end

  describe "start options" do
    test ":subscribe — subscribes caller at start" do
      {:ok, agent} = start_agent(subscribe: true)
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)
    end

    test ":subscribers — subscribes all given pids at start" do
      test_pid = self()
      helper = spawn_link(fn -> loop_forward(test_pid, :h) end)

      {:ok, agent} = start_agent(subscribe: false, subscribers: [self(), helper])
      :ok = Agent.prompt(agent, "Hello!")

      caller_events = collect_events(agent)
      helper_events = collect_forwarded(:h, agent)

      assert {:turn, {:stop, _}} = List.last(caller_events)
      assert {:turn, {:stop, _}} = List.last(helper_events)
    end

    test "no subscribers — caller receives no events" do
      {:ok, agent} = start_agent(subscribe: false)
      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(200)
      refute_receive {:agent, ^agent, _, _}, 50
    end
  end

  describe "late-join consistency" do
    test "snapshot + post-subscribe :message events reconstruct final state.messages" do
      # Start without subscribing so the user message is already appended
      # to pending by the time we subscribe.
      {:ok, agent} =
        start_agent(
          subscribe: false,
          fixtures: [@text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Hello!")
      {:ok, snapshot} = Agent.subscribe(agent)

      events = collect_events(agent)
      assert {:turn, {:stop, _}} = List.last(events)

      post_messages = for {:message, m} <- events, do: m

      reconstructed =
        snapshot.state.messages ++ snapshot.pending ++ post_messages

      # Drop any post-sub message that's already in pending (it fired
      # before subscribe). The current pending at subscribe time was
      # captured in the snapshot — subsequent :message events are for
      # messages added after subscribe.
      final = Agent.get_state(agent, :messages)
      assert final == reconstructed
    end
  end

  # -- helpers --

  defp loop_forward(test_pid, tag) do
    receive do
      {:agent, _, _, _} = msg ->
        send(test_pid, {tag, msg})
        loop_forward(test_pid, tag)
    after
      5000 -> :ok
    end
  end

  defp collect_forwarded(tag, agent, acc \\ []) do
    receive do
      {^tag, {:agent, ^agent, :turn, {:stop, _} = data}} ->
        Enum.reverse([{:turn, data} | acc])

      {^tag, {:agent, ^agent, :turn, {:continue, _} = data}} ->
        collect_forwarded(tag, agent, [{:turn, data} | acc])

      {^tag, {:agent, ^agent, :error, reason}} ->
        Enum.reverse([{:error, reason} | acc])

      {^tag, {:agent, ^agent, type, data}} ->
        collect_forwarded(tag, agent, [{type, data} | acc])
    after
      5000 -> {:timeout, Enum.reverse(acc)}
    end
  end
end
