defmodule Omni.Agent.RegenerateTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Tree

  describe "regenerate/1" do
    test "at an assistant head creates a sibling" do
      {:ok, agent} = start_agent(fixtures: [@text_fixture, @text_fixture])

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      tree = Agent.get_state(agent, :tree)
      assert tree.path == [1, 2]

      :ok = Agent.regenerate(agent)
      _events = collect_events(agent)

      tree = Agent.get_state(agent, :tree)

      # Tree now has 3 nodes; node 2 and node 3 are both assistant siblings of user node 1
      assert Tree.size(tree) == 3
      assert tree.path == [1, 3]
      assert MapSet.new(Tree.children(tree, 1)) == MapSet.new([2, 3])
      assert Tree.get_node(tree, 3).message.role == :assistant
    end

    test "at a user head generates an assistant response (retry path)" do
      # Simulate the "HTTP error left a dangling user message" scenario:
      # manually seed a tree with a lone user message, then regenerate.
      user_msg = Omni.Message.new(role: :user, content: "Hello!")
      tree = Tree.push(%Tree{}, user_msg)

      {:ok, agent} = start_agent(tree: tree, fixture: @text_fixture)

      :ok = Agent.regenerate(agent)
      events = collect_events(agent)

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)

      tree = Agent.get_state(agent, :tree)
      assert Tree.size(tree) == 2
      assert tree.path == [1, 2]
      assert Tree.get_node(tree, 2).message.role == :assistant
    end

    test "returns {:error, :invalid_head} on an empty tree" do
      {:ok, agent} = start_agent()
      assert {:error, :invalid_head} = Agent.regenerate(agent)
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

      assert {:error, :streaming} = Agent.regenerate(agent)

      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "navigate + regenerate composition" do
    test "regenerate from a mid-tree assistant via explicit navigate first" do
      {:ok, agent} =
        start_agent(fixtures: [@text_fixture, @text_fixture, @text_fixture])

      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)

      :ok = Agent.prompt(agent, "Second")
      _events = collect_events(agent)

      # Tree: user(1) -> asst(2) -> user(3) -> asst(4)
      tree = Agent.get_state(agent, :tree)
      assert tree.path == [1, 2, 3, 4]

      # Compose: navigate to node 2 then regenerate — new assistant is sibling of 2
      :ok = Agent.navigate(agent, 2)
      :ok = Agent.regenerate(agent)
      _events = collect_events(agent)

      tree = Agent.get_state(agent, :tree)
      assert tree.path == [1, 5]
      assert MapSet.new(Tree.children(tree, 1)) == MapSet.new([2, 5])
      assert Tree.get_node(tree, 5).message.role == :assistant
    end
  end

  describe "branching preservation" do
    test "regenerate then navigate back to original branch" do
      {:ok, agent} = start_agent(fixtures: [@text_fixture, @text_fixture])

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      :ok = Agent.regenerate(agent)
      _events = collect_events(agent)

      # Active path is now [1, 3]; the original branch [1, 2] is still reachable
      :ok = Agent.navigate(agent, 2)

      tree = Agent.get_state(agent, :tree)
      assert tree.path == [1, 2]
      assert Tree.size(tree) == 3
    end
  end
end
