defmodule Omni.Agent.NavigateTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Tree

  describe "navigate/2" do
    test "moves the active path and emits a :tree event" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      tree = Agent.get_state(agent, :tree)
      assert Tree.size(tree) == 2

      # Navigate back to the user node (id 1) — active path becomes [1]
      :ok = Agent.navigate(agent, 1)

      new_tree = Agent.get_state(agent, :tree)
      assert new_tree.path == [1]

      assert_receive {:agent, ^agent, :tree, %Tree{path: [1]}}
    end

    test "navigate to nil clears the active path" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      :ok = Agent.navigate(agent, nil)

      tree = Agent.get_state(agent, :tree)
      assert tree.path == []
      # Nodes still present — navigate only moves the cursor
      assert Tree.size(tree) == 2
    end

    test "returns {:error, :not_found} for unknown id" do
      {:ok, agent} = start_agent()
      assert {:error, :not_found} = Agent.navigate(agent, 99)
    end

    test "returns {:error, :streaming} while running" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)

      assert {:error, :streaming} = Agent.navigate(agent, 1)

      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end

    test "returns {:error, :streaming} while paused" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, _}} = List.last(events)

      assert {:error, :streaming} = Agent.navigate(agent, 1)

      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end
end
