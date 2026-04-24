defmodule Omni.Session.PersistenceTest do
  use Omni.Session.SessionCase, async: true

  @moduletag :tmp_dir

  describe "turn commit" do
    test "one-turn prompt persists tree and emits :tree + :store events", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.prompt(session, "Hello")
      events = collect_session_events(session)

      # Event ordering: :turn → :tree → :store {:saved, :tree}
      turn_idx = Enum.find_index(events, &match?({:turn, {:stop, _}}, &1))
      tree_idx = Enum.find_index(events, &match?({:tree, _}, &1))
      store_idx = Enum.find_index(events, &match?({:store, {:saved, :tree}}, &1))

      assert turn_idx < tree_idx
      assert tree_idx < store_idx

      {:tree, %{tree: tree, new_nodes: ids}} = Enum.at(events, tree_idx)
      assert Tree.size(tree) == 2
      assert length(ids) == 2

      # Nodes are persisted to the filesystem adapter.
      store = tmp_store(ctx)
      {:ok, loaded_tree, _} = Store.load(store, "s1")
      assert Tree.messages(loaded_tree) == Tree.messages(tree)
    end

    test "usage is attached to the last assistant node only", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.prompt(session, "Hello")
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      nodes = Map.values(tree.nodes) |> Enum.sort_by(& &1.id)

      assert Enum.at(nodes, 0).message.role == :user
      assert Enum.at(nodes, 0).usage == nil

      assert Enum.at(nodes, 1).message.role == :assistant
      assert %Usage{} = Enum.at(nodes, 1).usage
      assert Enum.at(nodes, 1).usage.total_tokens > 0
    end
  end

  describe "multi-turn persistence" do
    test "each prompt accretes to the tree", ctx do
      {session, _} =
        start_session(ctx, new: "s1", fixtures: [@text_fixture, @text_fixture])

      :ok = Session.prompt(session, "First")
      _ = collect_session_events(session)
      :ok = Session.prompt(session, "Second")
      _ = collect_session_events(session)

      tree = Session.get_tree(session)
      assert Tree.size(tree) == 4
    end

    test "continuation: per-turn usage attaches to each turn's assistant", ctx do
      {session, _} =
        start_session(ctx,
          new: "s1",
          agent_module: ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Session.prompt(session, "Start")
      _ = collect_session_events(session)

      tree = Session.get_tree(session)

      assistant_nodes =
        tree.nodes
        |> Map.values()
        |> Enum.filter(&(&1.message.role == :assistant))
        |> Enum.sort_by(& &1.id)

      # 3 turns × 1 assistant each
      assert length(assistant_nodes) == 3
      usages = Enum.map(assistant_nodes, & &1.usage.total_tokens)

      # All three turns used the same fixture, so their usages should
      # be equal — the Agent's per-turn turn_usage reset guarantees
      # usages don't accumulate across continuations.
      assert Enum.uniq(usages) |> length() == 1
    end
  end

  describe "load round-trip" do
    test "persisted session reopens with full conversation restored", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.prompt(session, "Hello")
      _ = collect_session_events(session)
      original_tree = Session.get_tree(session)

      :ok = Session.stop(session)

      # Reopen.
      {:ok, reopened} =
        Session.start_link(
          load: "s1",
          agent: [model: model(), opts: [api_key: "test-key"]],
          store: tmp_store(ctx),
          subscribe: true
        )

      assert Session.get_tree(reopened) == original_tree
      assert Session.get_agent(reopened, :messages) == Tree.messages(original_tree)
    end
  end

  describe "cancel/error do not corrupt persisted state" do
    test "cancel discards turn_messages; tree untouched", ctx do
      {session, stub_name} = start_session(ctx, new: "s1", fixture: @text_fixture)

      # First, complete one turn so the tree has something in it.
      :ok = Session.prompt(session, "Committed")
      _ = collect_session_events(session)
      committed_tree = Session.get_tree(session)
      assert Tree.size(committed_tree) == 2

      # Replace the stub with a receive-gated variant so the next call blocks
      # until the test releases — guarantees cancel arrives in-flight.
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

      :ok = Session.prompt(session, "Will be cancelled")
      assert_receive {:llm_called, ^gate_ref, plug_pid}, 2000
      :ok = Session.cancel(session)
      send(plug_pid, {:release, gate_ref})
      _ = collect_session_events(session)

      after_cancel_tree = Session.get_tree(session)
      assert after_cancel_tree == committed_tree
    end
  end

  describe "store errors" do
    test ":store {:error, :tree, reason} event fires, session continues", ctx do
      failing_store = {
        Omni.Session.Store.Failing,
        fail_save_tree: :disk_full, delegate: tmp_store(ctx)
      }

      {session, _} = start_session(ctx, new: "s1", store: failing_store)

      :ok = Session.prompt(session, "Hello")
      events = collect_session_events(session)

      assert {:store, {:error, :tree, :disk_full}} in events
      assert Process.alive?(session)
    end

    test ":store {:error, :state, reason} event fires, session continues", ctx do
      failing_store = {
        Omni.Session.Store.Failing,
        fail_save_state: :disk_full, delegate: tmp_store(ctx)
      }

      {session, _} = start_session(ctx, new: "s1", store: failing_store)

      # set_title flows through persist_state_if_changed — the title is
      # part of the persistable subset, so this triggers a save_state.
      :ok = Session.set_title(session, "A new title")

      assert_receive {:session, ^session, :store, {:error, :state, :disk_full}}, 2000
      assert Process.alive?(session)
    end
  end
end
