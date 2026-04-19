defmodule Omni.Session.LifecycleTest do
  use Omni.Session.SessionCase, async: true

  @moduletag :tmp_dir

  describe "start_link/1 mode resolution" do
    test "no :new or :load → auto-generated id", ctx do
      {session, _} = start_session(ctx)
      id = :sys.get_state(session).id

      assert is_binary(id)
      # 16 random bytes → 22 url-safe base64 chars (no padding)
      assert byte_size(id) == 22
      assert String.match?(id, ~r/^[A-Za-z0-9_-]{22}$/)
    end

    test "new: :auto produces a generated id", ctx do
      {s1, _} = start_session(ctx, new: :auto)
      {s2, _} = start_session(ctx, new: :auto)

      assert :sys.get_state(s1).id != :sys.get_state(s2).id
    end

    test "new: \"explicit\" uses the given id", ctx do
      {session, _} = start_session(ctx, new: "my-session")
      assert :sys.get_state(session).id == "my-session"
    end

    test "both :new and :load → :ambiguous_mode", ctx do
      Process.flag(:trap_exit, true)

      {:error, :ambiguous_mode} =
        Session.start_link(
          new: "a",
          load: "b",
          agent: [model: model()],
          store: tmp_store(ctx)
        )
    end

    test "missing :agent → :missing_agent", ctx do
      Process.flag(:trap_exit, true)
      {:error, :missing_agent} = Session.start_link(new: :auto, store: tmp_store(ctx))
    end

    test "missing :store → :missing_store", _ctx do
      Process.flag(:trap_exit, true)
      {:error, :missing_store} = Session.start_link(new: :auto, agent: [model: model()])
    end
  end

  describe "new-mode validation" do
    test "rejects agent: [messages: _]", ctx do
      Process.flag(:trap_exit, true)

      {:error, :initial_messages_not_supported} =
        Session.start_link(
          new: :auto,
          agent: [model: model(), messages: [Message.new(role: :user, content: "hi")]],
          store: tmp_store(ctx)
        )
    end
  end

  describe "load-mode" do
    test "returns :not_found when the session isn't in the store", ctx do
      Process.flag(:trap_exit, true)

      {:error, :not_found} =
        Session.start_link(
          load: "missing",
          agent: [model: model()],
          store: tmp_store(ctx)
        )
    end

    test ":no_model when neither persisted nor start opt has a usable model", ctx do
      store = tmp_store(ctx)
      # Persist a tree + state with an unregistered model.
      :ok =
        Store.save_state(store, "s1", %{model: {:nonexistent_provider, "bogus"}})

      :ok = Store.save_tree(store, "s1", %Tree{})

      Process.flag(:trap_exit, true)

      {:error, :no_model} =
        Session.start_link(load: "s1", agent: [], store: store)
    end

    test "falls back to start-opt model when persisted model is unresolvable", ctx do
      store = tmp_store(ctx)
      :ok = Store.save_state(store, "s1", %{model: {:nonexistent_provider, "bogus"}})
      :ok = Store.save_tree(store, "s1", %Tree{})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [model: model()],
          store: store
        )

      agent_state = Session.get_agent(session)
      assert agent_state.model == model()
    end

    test "ignores agent: [messages: _] silently on load", ctx do
      store = tmp_store(ctx)

      tree =
        %Tree{}
        |> Tree.push(Message.new(role: :user, content: "persisted"))
        |> Tree.push(Message.new(role: :assistant, content: "response"))

      :ok = Store.save_tree(store, "s1", tree)
      :ok = Store.save_state(store, "s1", %{model: {:anthropic, "claude-haiku-4-5"}})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [messages: [Message.new(role: :user, content: "ignored")]],
          store: store
        )

      assert Session.get_agent(session, :messages) == Tree.messages(tree)
    end
  end

  describe "stop/1" do
    test "stops session and linked agent", ctx do
      {session, _} = start_session(ctx)
      agent = :sys.get_state(session).agent
      ref = Process.monitor(agent)

      :ok = Session.stop(session)

      assert_receive {:DOWN, ^ref, :process, ^agent, _}, 1000
      refute Process.alive?(session)
    end
  end

  describe "agent crash propagation" do
    test "agent crash takes session down with it", ctx do
      Process.flag(:trap_exit, true)
      {session, _} = start_session(ctx, subscribe: false)
      agent = :sys.get_state(session).agent

      ref = Process.monitor(session)
      Process.exit(agent, :kill)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 1000
    end
  end
end
