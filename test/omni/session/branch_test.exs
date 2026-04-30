defmodule Omni.Session.BranchTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Agent.TestAgents.PauseAgent

  @moduletag :tmp_dir

  describe "branch/3 (edit — target an assistant with new content)" do
    test "creates a new user+turn branching off the target assistant", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)
      # Tree: [u1 → a2]. Now branch off a2 with new content.

      :ok = Session.branch(session, 2, "B'")
      events = collect_session_events(session)

      # One :tree with empty new_nodes (navigate); one with new_nodes
      # from the turn commit.
      tree_events = Enum.filter(events, &match?({:tree, _}, &1))
      assert length(tree_events) == 2
      assert {_, %{new_nodes: []}} = hd(tree_events)
      assert {_, %{new_nodes: [u_id, a_id]}} = List.last(tree_events)

      tree = Session.get_tree(session)
      # a2 now has one child: the new user message.
      assert Tree.children(tree, 2) == [u_id]
      # New user has one child: new assistant.
      assert Tree.children(tree, u_id) == [a_id]
      # Cursor at a2 points to the new user branch.
      assert tree.cursors[2] == u_id
      # Active path ends on new assistant.
      assert Tree.head(tree) == a_id
    end

    test "target is a user node: returns :not_assistant_node", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)

      # Node 1 is the user root.
      assert {:error, :not_assistant_node} = Session.branch(session, 1, "B")
    end

    test "unknown id: returns :not_found", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)

      assert {:error, :not_found} = Session.branch(session, 999, "B")
    end

    test "nil target: creates a disjoint new root with the given content", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "first root")
      _ = collect_session_events(session)
      # Tree: [u1 → a2]

      :ok = Session.branch(session, nil, "second root")
      events = collect_session_events(session)

      # :tree with no new_nodes (navigate to nil) + :tree with two new
      # nodes (turn commit of new root turn).
      tree_events = Enum.filter(events, &match?({:tree, _}, &1))
      assert length(tree_events) == 2
      assert {_, %{new_nodes: [u_id, a_id]}} = List.last(tree_events)

      tree = Session.get_tree(session)
      assert Enum.sort(Tree.roots(tree)) == [1, u_id]
      assert Tree.get_node(tree, u_id).parent_id == nil
      assert Tree.get_node(tree, u_id).message.role == :user
      assert Tree.get_node(tree, a_id).parent_id == u_id
      assert Tree.get_node(tree, a_id).message.role == :assistant
    end
  end

  describe "branch/2 (regen — target a user, reuse its content)" do
    test "pushes a sibling assistant as a child of the user", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "ask")
      _ = collect_session_events(session)
      # Tree: [u1 → a2]. Now regen the turn of u1.

      original_assistant_id = Tree.head(Session.get_tree(session))
      assert original_assistant_id == 2

      :ok = Session.branch(session, 1)
      events = collect_session_events(session)

      tree_events = Enum.filter(events, &match?({:tree, _}, &1))
      # Navigate fires one :tree; turn commits another.
      assert length(tree_events) == 2
      # Turn commit should only push ONE new node (leading user dropped).
      assert {_, %{new_nodes: [new_a_id]}} = List.last(tree_events)

      tree = Session.get_tree(session)
      # u1 now has two assistant children.
      assert Enum.sort(Tree.children(tree, 1)) == Enum.sort([original_assistant_id, new_a_id])
      # Cursor at u1 is the new assistant.
      assert tree.cursors[1] == new_a_id
      # Active path ends on the new assistant.
      assert Tree.head(tree) == new_a_id
      # Original assistant message is still present, unmutated.
      assert Tree.get_node(tree, original_assistant_id) != nil
    end

    test "clears regen_source after the first turn commit", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "ask")
      _ = collect_session_events(session)

      :ok = Session.branch(session, 1)
      _ = collect_session_events(session)

      assert :sys.get_state(session).regen_source == nil
    end

    test "root user regen: agent messages are empty; first turn drops duplicate", ctx do
      {session, _} = start_session(ctx, fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "root")
      _ = collect_session_events(session)
      # u1 is root.

      :ok = Session.branch(session, 1)
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      # u1 still has exactly one user with two assistant children.
      children = Tree.children(tree, 1)
      assert length(children) == 2

      Enum.each(children, fn id ->
        assert Tree.get_node(tree, id).message.role == :assistant
      end)
    end

    test "target is an assistant node: returns :not_user_node", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "hi")
      _ = collect_session_events(session)

      assert {:error, :not_user_node} = Session.branch(session, 2)
    end

    test "unknown id: returns :not_found", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.prompt(session, "hi")
      _ = collect_session_events(session)

      assert {:error, :not_found} = Session.branch(session, 999)
    end
  end

  describe "idle gate" do
    test "branch/2 during paused turn: returns :paused", ctx do
      {session, _} =
        start_session(ctx,
          agent_module: PauseAgent,
          agent_opts: [tools: [get_weather_tool()]],
          fixture: @tool_use_fixture
        )

      :ok = Session.prompt(session, "Use the tool")
      assert_receive {:session, ^session, :pause, _}, 1000

      # Doesn't matter that node 1 exists — idle check short-circuits.
      assert {:error, :paused} = Session.branch(session, 1)
    end

    test "branch/3 during paused turn: returns :paused", ctx do
      {session, _} =
        start_session(ctx,
          agent_module: PauseAgent,
          agent_opts: [tools: [get_weather_tool()]],
          fixture: @tool_use_fixture
        )

      :ok = Session.prompt(session, "Use the tool")
      assert_receive {:session, ^session, :pause, _}, 1000

      assert {:error, :paused} = Session.branch(session, 2, "new")
    end
  end

  describe "cancelled edit (branch/3 with assistant target + content)" do
    test "rolls back to pre-branch tree; no children appear", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      # First turn seeds user:1 → assistant:2.
      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)

      # Gate the branch's LLM call so we can cancel while it's in-flight.
      parent = self()
      gate_ref = make_ref()

      Req.Test.stub(stub_name, fn conn ->
        send(parent, {:llm_called, gate_ref, self()})

        receive do
          {:release, ^gate_ref} -> :ok
        end

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok = Session.branch(session, 2, "B")
      assert_receive {:llm_called, ^gate_ref, plug_pid}, 2000
      :ok = Session.cancel(session)
      send(plug_pid, {:release, gate_ref})
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      # Cancel rollback restores the pre-branch tree and extends to a
      # tip — pre-branch was already at the [1, 2] tip, so extend is a
      # no-op.
      assert tree.path == [1, 2]
      assert Tree.children(tree, 2) == []
      assert Tree.size(tree) == 2
      # Agent messages stay coherent with the restored tree.
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
      # Both rollback flags are cleared.
      assert :sys.get_state(session).regen_source == nil
      assert :sys.get_state(session).pre_branch_tree == nil
    end
  end

  describe "errored edit (branch/3 with assistant target + content)" do
    test "rolls back to pre-branch tree; no children appear", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)

      # Next call 500s — the default handle_error returns {:stop, state}.
      Req.Test.stub(stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      :ok = Session.branch(session, 2, "B")
      events = collect_session_events(session)

      assert Enum.any?(events, &match?({:error, _}, &1))

      tree = Session.get_tree(session)
      assert tree.path == [1, 2]
      assert Tree.children(tree, 2) == []
      assert Tree.size(tree) == 2
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
      assert :sys.get_state(session).regen_source == nil
      assert :sys.get_state(session).pre_branch_tree == nil
    end
  end

  describe "cancelled regen" do
    test "cancelling a regen clears regen_source and restores pre-branch tree", ctx do
      {session, _} =
        start_session(ctx,
          agent_module: PauseAgent,
          agent_opts: [tools: [get_weather_tool()]],
          fixtures: [@text_fixture, @tool_use_fixture]
        )

      # First turn establishes a user root (node 1) + assistant (node 2)
      # via the text fixture.
      :ok = Session.prompt(session, "Plain text")
      _ = collect_session_events(session)
      assert Session.get_agent(session, :status) == :idle

      # Now regen node 1 — the second fixture is a tool-use response,
      # which PauseAgent will pause on.
      :ok = Session.branch(session, 1)
      assert_receive {:session, ^session, :pause, _}, 1000

      # regen_source and pre_branch_tree are set during the in-flight
      # regen. Tree path is on the user (node 1) until commit.
      assert :sys.get_state(session).regen_source == 1
      assert %Tree{path: [1, 2]} = :sys.get_state(session).pre_branch_tree

      :ok = Session.cancel(session)
      assert_receive {:session, ^session, :cancelled, _}, 1000
      _ = collect_session_events(session)

      # Tree rolls back to the pre-branch state, agent messages match,
      # both rollback flags are cleared.
      tree = Session.get_tree(session)
      assert tree.path == [1, 2]
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
      assert :sys.get_state(session).regen_source == nil
      assert :sys.get_state(session).pre_branch_tree == nil
    end
  end

  describe "errored regen" do
    test "rolls back to pre-branch tree on error mid-regen", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      :ok = Session.prompt(session, "ask")
      _ = collect_session_events(session)
      # Pre-branch tree: [u1, a2].

      # Next call 500s. The regen fires its prompt against this stub.
      Req.Test.stub(stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      :ok = Session.branch(session, 1)
      events = collect_session_events(session)

      assert Enum.any?(events, &match?({:error, _}, &1))

      tree = Session.get_tree(session)
      assert tree.path == [1, 2]
      assert Tree.children(tree, 1) == [2]
      assert Tree.size(tree) == 2
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
      assert :sys.get_state(session).regen_source == nil
      assert :sys.get_state(session).pre_branch_tree == nil
    end
  end

  describe "cancelled branch from nil" do
    test "rolls back to pre-branch path; no new root appears", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)
      # Pre-branch tree: [u1, a2].

      parent = self()
      gate_ref = make_ref()

      Req.Test.stub(stub_name, fn conn ->
        send(parent, {:llm_called, gate_ref, self()})

        receive do
          {:release, ^gate_ref} -> :ok
        end

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok = Session.branch(session, nil, "new root")
      assert_receive {:llm_called, ^gate_ref, plug_pid}, 2000

      # During the in-flight branch, the path was cleared by the nil nav.
      assert Session.get_tree(session).path == []

      :ok = Session.cancel(session)
      send(plug_pid, {:release, gate_ref})
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      # Path restored, no new nodes appeared.
      assert tree.path == [1, 2]
      assert Tree.size(tree) == 2
      assert Tree.roots(tree) == [1]
      assert Session.get_agent(session, :messages) == Tree.messages(tree)
      assert :sys.get_state(session).pre_branch_tree == nil
    end
  end

  describe "cancel-rollback cursor preservation" do
    test "branch + cancel + navigate from ancestor uses original cursors", ctx do
      {session, stub_name} =
        start_session(ctx,
          new: "s1",
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      # Build tree [u1, a2] then a sibling branch [u1, a3] via regen.
      :ok = Session.prompt(session, "ask")
      _ = collect_session_events(session)
      :ok = Session.branch(session, 1)
      _ = collect_session_events(session)
      # Cursor at u1 now points to a3 (the most-recently-committed branch).
      assert Session.get_tree(session).cursors[1] == 3

      # Now start an edit-branch from a3 but cancel it mid-flight.
      parent = self()
      gate_ref = make_ref()

      Req.Test.stub(stub_name, fn conn ->
        send(parent, {:llm_called, gate_ref, self()})

        receive do
          {:release, ^gate_ref} -> :ok
        end

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok = Session.branch(session, 3, "edit a3")
      assert_receive {:llm_called, ^gate_ref, plug_pid}, 2000
      :ok = Session.cancel(session)
      send(plug_pid, {:release, gate_ref})
      _ = collect_session_events(session)

      # Cursors restored — u1 still points to a3, no in-flight branch
      # leaks into navigation.
      tree = Session.get_tree(session)
      assert tree.cursors[1] == 3

      # Navigate from u1 lands back on a3, not on any phantom child.
      :ok = Session.navigate(session, 1)
      assert Session.get_tree(session).path == [1, 3]
    end
  end

  describe "cancel-rollback event order" do
    test "emits :cancelled then :tree then :state", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      :ok = Session.prompt(session, "A")
      _ = collect_session_events(session)

      parent = self()
      gate_ref = make_ref()

      Req.Test.stub(stub_name, fn conn ->
        send(parent, {:llm_called, gate_ref, self()})

        receive do
          {:release, ^gate_ref} -> :ok
        end

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      :ok = Session.branch(session, 2, "B")
      assert_receive {:llm_called, ^gate_ref, plug_pid}, 2000
      :ok = Session.cancel(session)
      send(plug_pid, {:release, gate_ref})

      events = collect_session_events(session)

      # Slice from :cancelled onward — the branch's own apply_navigation
      # also emits :tree / :store / :state before the cancel, which we
      # don't care about here.
      tail =
        events
        |> Enum.map(&elem(&1, 0))
        |> Enum.drop_while(&(&1 != :cancelled))

      tree_idx = Enum.find_index(tail, &(&1 == :tree))
      store_idx = Enum.find_index(tail, &(&1 == :store))
      state_idx = Enum.find_index(tail, &(&1 == :state))

      assert tail != []
      assert tree_idx != nil
      assert store_idx != nil
      assert state_idx != nil

      # Documented event order: :cancelled → :tree → :store → :state.
      assert hd(tail) == :cancelled
      assert tree_idx < store_idx
      assert store_idx < state_idx
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
