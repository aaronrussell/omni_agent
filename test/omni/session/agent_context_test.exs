defmodule Omni.Session.AgentContextTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Agent.TestAgents.CapturesOmni

  @moduletag :tmp_dir

  describe "private[:omni] injection" do
    test "session writes :omni into agent private with id and pid", ctx do
      {session, _} = start_session(ctx, new: "s1")

      private = Session.get_agent(session, :private)
      assert %{omni: %{session_id: "s1", session_pid: ^session}} = private
    end

    test "init/1 sees the :omni map", ctx do
      {session, _} =
        start_session(ctx, new: "s1", agent_module: CapturesOmni)

      private = Session.get_agent(session, :private)
      assert private[:captured] == %{session_id: "s1", session_pid: session}
    end

    test "user-supplied :private keys survive alongside :omni", ctx do
      {session, _} =
        start_session(ctx, new: "s1", agent_opts: [private: %{user_key: "preserved"}])

      private = Session.get_agent(session, :private)
      assert private[:user_key] == "preserved"
      assert %{session_id: "s1"} = private[:omni]
    end

    test "user-supplied :private[:omni] is overwritten by Session", ctx do
      {session, _} =
        start_session(ctx,
          new: "s1",
          agent_opts: [private: %{omni: :user_value, other: 42}]
        )

      private = Session.get_agent(session, :private)
      assert %{session_id: "s1", session_pid: ^session} = private[:omni]
      assert private[:other] == 42
    end

    test ":omni reflects the loaded id on load mode", ctx do
      store = tmp_store(ctx)
      :ok = Store.save_tree(store, "s1", %Tree{})
      :ok = Store.save_state(store, "s1", %{model: {:anthropic, "claude-haiku-4-5"}})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: {CapturesOmni, [model: model()]},
          store: store
        )

      private = Session.get_agent(session, :private)
      assert private[:captured] == %{session_id: "s1", session_pid: session}

      Session.stop(session)
    end
  end
end
