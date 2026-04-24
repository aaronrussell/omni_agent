defmodule Omni.Session.NavigationTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Agent.TestAgents.PauseAgent

  @moduletag :tmp_dir

  describe "navigate/2" do
    test "to existing assistant: path updated, agent resynced, :tree with no new_nodes", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])
      :ok = Session.prompt(session, "first")
      _ = collect_session_events(session)
      :ok = Session.prompt(session, "second")
      _ = collect_session_events(session)

      # Tree now has 4 nodes: u1, a2, u3, a4 (head = a4)
      :ok = Session.navigate(session, 2)

      assert_receive {:session, ^session, :tree, %{new_nodes: []}}, 1000
      assert_receive {:session, ^session, :store, {:saved, :tree}}, 1000

      tree = Session.get_tree(session)
      assert tree.path == [1, 2]
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
    end

    test "unknown id: returns :not_found; tree untouched", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "hi")
      _ = collect_session_events(session)

      original = Session.get_tree(session)
      assert {:error, :not_found} = Session.navigate(session, 999)
      assert Session.get_tree(session) == original
    end

    test "nil: clears the path; subsequent prompt creates a disjoint root", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])
      :ok = Session.prompt(session, "first")
      _ = collect_session_events(session)

      :ok = Session.navigate(session, nil)
      assert Session.get_tree(session).path == []

      :ok = Session.prompt(session, "second root")
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      assert Enum.sort(Tree.roots(tree)) == [1, 3]
    end

    test "to a user node: agent rejects; tree not mutated", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "hi")
      _ = collect_session_events(session)

      # Node 1 is the user root. Navigating to it would leave path on
      # a user message, violating the Agent's messages invariant.
      assert {:error, :invalid_messages} = Session.navigate(session, 1)
      assert Session.get_tree(session).path == [1, 2]
    end

    test "does not trigger save_state", ctx do
      {session, _} =
        start_session(ctx, new: "s1", fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "first")
      _ = collect_session_events(session)
      :ok = Session.prompt(session, "second")
      _ = collect_session_events(session)

      :ok = Session.navigate(session, 2)
      assert_receive {:session, ^session, :store, {:saved, :tree}}, 1000
      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end

    test "during a paused turn: returns :paused", ctx do
      {session, _} =
        start_session(ctx,
          agent_module: PauseAgent,
          agent_opts: [tools: [get_weather_tool()]],
          fixture: @tool_use_fixture
        )

      :ok = Session.prompt(session, "Use the tool")
      assert_receive {:session, ^session, :pause, _}, 1000
      assert Session.get_agent(session, :status) == :paused

      assert {:error, :paused} = Session.navigate(session, 1)
    end
  end

  defp get_weather_tool do
    Omni.tool(
      name: "get_weather",
      description: "Gets the weather",
      input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
      handler: fn _ -> "72F and sunny" end
    )
  end
end
