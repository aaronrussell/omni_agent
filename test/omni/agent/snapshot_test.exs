defmodule Omni.Agent.SnapshotTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Snapshot
  alias Omni.Message

  describe "get_snapshot/1" do
    test "idle agent: empty pending, nil partial" do
      {:ok, agent} = start_agent()
      snapshot = Agent.get_snapshot(agent)

      assert %Snapshot{pending: [], partial: nil} = snapshot
      assert snapshot.state.status == :idle
      assert snapshot.state.messages == []
    end

    test "after a completed turn: committed in state.messages, pending empty, partial nil" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      snapshot = Agent.get_snapshot(agent)
      assert snapshot.pending == []
      assert snapshot.partial == nil
      assert length(snapshot.state.messages) == 2
    end

    test "while running: pending contains the user message, partial tracks streaming" do
      # Slow stub so we can observe the agent while it's running.
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 300)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")

      # Give the server a moment to spawn the step task and receive events.
      Process.sleep(50)

      snapshot = Agent.get_snapshot(agent)
      assert snapshot.state.status == :running
      assert [%Message{role: :user}] = snapshot.pending
      # Note: :partial may be nil or a streaming message depending on how
      # far the stream has gotten. Both are consistent with the invariant —
      # the point is that get_snapshot returns a well-formed Snapshot.
      case snapshot.partial do
        nil -> :ok
        %Message{role: :assistant} -> :ok
      end

      # Drain until the turn completes so we don't leak the running agent.
      _events = collect_events(agent, 2000)
    end

    test "partial is cleared after :message event for the assistant" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      snapshot = Agent.get_snapshot(agent)
      assert snapshot.partial == nil
    end

    test "pending resets to empty after :turn {:stop, _}" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      _events = collect_events(agent)

      snapshot = Agent.get_snapshot(agent)
      assert snapshot.pending == []
      assert snapshot.partial == nil
      # ContinueAgent runs three segments before stopping.
      assert length(snapshot.state.messages) == 6
    end
  end

  describe "subscribe returns snapshot" do
    test "idle: snapshot matches get_snapshot" do
      {:ok, agent} = start_agent(subscribe: false)

      {:ok, subscribed} = Agent.subscribe(agent)
      direct = Agent.get_snapshot(agent)

      assert subscribed.pending == direct.pending
      assert subscribed.partial == direct.partial
      assert subscribed.state.messages == direct.state.messages
    end
  end
end
