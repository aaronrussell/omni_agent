defmodule Omni.Session.NavigationTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Agent.TestAgents.PauseAgent

  @moduletag :tmp_dir

  describe "navigate/2" do
    test "to a sibling branch: path updated, agent resynced, :tree with no new_nodes", ctx do
      {session, _} =
        start_session(ctx, fixtures: [@text_fixture, @text_fixture, @text_fixture])

      :ok = Session.prompt(session, "ask")
      _ = collect_session_events(session)
      # Tree: [u1, a2]

      # Regen u1 to create a sibling assistant a3 under u1.
      :ok = Session.branch(session, 1)
      _ = collect_session_events(session)
      # Tree now has [u1, a2] and [u1, a3]; head = a3, cursor[1] = 3.

      :ok = Session.navigate(session, 2)
      assert_receive {:session, ^session, :tree, %{new_nodes: []}}, 1000
      assert_receive {:session, ^session, :store, {:saved, :tree}}, 1000

      tree = Session.get_tree(session)
      # a2 is a leaf, so extend is a no-op — path lands exactly there.
      assert tree.path == [1, 2]
      assert tree.cursors[1] == 2
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

    test "to a user node: extends to the cursor's assistant child", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "hi")
      _ = collect_session_events(session)

      # Tree: [u1, a2]. Navigating to user 1 should extend down via
      # cursors and land on a2 — navigation always lands on a tip.
      :ok = Session.navigate(session, 1)

      tree = Session.get_tree(session)
      assert tree.path == [1, 2]
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
    end

    test "to a non-leaf assistant: extends along cursors to a leaf", ctx do
      {session, _} =
        start_session(ctx, fixtures: [@text_fixture, @text_fixture, @text_fixture])

      # Build [u1, a2, u3, a4] then a sibling branch off a2.
      :ok = Session.prompt(session, "first")
      _ = collect_session_events(session)
      :ok = Session.prompt(session, "second")
      _ = collect_session_events(session)

      :ok = Session.branch(session, 2, "alt second")
      _ = collect_session_events(session)
      # Tree now has [u1, a2, u3, a4] and [u1, a2, u5, a6]. The branch
      # commit just left cursor at a2 → u5 (the new branch).

      tree_before = Session.get_tree(session)
      assert tree_before.cursors[2] == 5

      # Navigate to a2 — extend should follow the cursor down to a6.
      :ok = Session.navigate(session, 2)
      tree = Session.get_tree(session)
      assert tree.path == [1, 2, 5, 6]
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
    end

    test "to a leaf assistant: no extension, lands exactly there", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "first")
      _ = collect_session_events(session)
      :ok = Session.prompt(session, "second")
      _ = collect_session_events(session)

      :ok = Session.navigate(session, 4)
      assert Session.get_tree(session).path == [1, 2, 3, 4]
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
