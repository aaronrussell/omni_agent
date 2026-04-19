defmodule Omni.Session.StateTest do
  use Omni.Session.SessionCase, async: true

  @moduletag :tmp_dir

  describe "set_agent/2,3 passthrough" do
    test "delegates to Agent.set_state/2", ctx do
      {session, _} = start_session(ctx)

      :ok = Session.set_agent(session, system: "Be concise.")
      assert Session.get_agent(session, :system) == "Be concise."
    end

    test "delegates to Agent.set_state/3", ctx do
      {session, _} = start_session(ctx)

      :ok = Session.set_agent(session, :system, "Updated.")
      assert Session.get_agent(session, :system) == "Updated."
    end

    test "forwards :state event to subscribers", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.set_agent(session, :system, "New")

      assert_receive {:session, ^session, :state, %Omni.Agent.State{system: "New"}}, 1000
    end
  end

  describe ":state event change-detection" do
    test "changing :system triggers save_state and emits :store {:saved, :state}", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.set_agent(session, :system, "Persist me")
      assert_receive {:session, ^session, :store, {:saved, :state}}, 1000

      # Verify it actually hit disk.
      {:ok, _tree, state_map} = Store.load(tmp_store(ctx), "s1")
      assert state_map[:system] == "Persist me"
    end

    test "changing :model triggers save_state", ctx do
      {session, _} = start_session(ctx, new: "s1")

      {:ok, other_model} = Omni.get_model(:anthropic, "claude-sonnet-4-5")
      :ok = Session.set_agent(session, :model, other_model)

      assert_receive {:session, ^session, :store, {:saved, :state}}, 1000

      {:ok, _tree, state_map} = Store.load(tmp_store(ctx), "s1")
      assert state_map[:model] == Omni.Model.to_ref(other_model)
    end

    test "changing :tools does NOT trigger save_state (tools not persisted)", ctx do
      {session, _} = start_session(ctx, new: "s1")

      tool =
        Omni.tool(
          name: "noop",
          description: "",
          input_schema: %{type: "object", properties: %{}}
        )

      :ok = Session.set_agent(session, :tools, [tool])

      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end

    test "reordered :opts does not trigger spurious save_state", ctx do
      original_opts = [temperature: 0.5, max_tokens: 100]

      {session, _} =
        start_session(ctx, new: "s1", agent_opts: [opts: original_opts])

      # Changing to a reordering of the same keyword list must not be
      # seen as a change — Session canonicalises via Enum.sort/1.
      reordered = [max_tokens: 100, temperature: 0.5]
      :ok = Session.set_agent(session, :opts, reordered)

      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end

    test "identical re-set does not trigger save_state", ctx do
      {session, _} = start_session(ctx, new: "s1")
      current = Session.get_agent(session, :system)

      :ok = Session.set_agent(session, :system, current)
      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end
  end

  describe "load-mode resolution" do
    test "start opt :system wins over persisted", ctx do
      store = tmp_store(ctx)

      :ok =
        Store.save_state(store, "s1", %{
          model: {:anthropic, "claude-haiku-4-5"},
          system: "Old"
        })

      :ok = Store.save_tree(store, "s1", %Tree{})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [system: "New"],
          store: store
        )

      assert Session.get_agent(session, :system) == "New"
    end

    test "persisted :system used when start opt absent", ctx do
      store = tmp_store(ctx)

      :ok =
        Store.save_state(store, "s1", %{
          model: {:anthropic, "claude-haiku-4-5"},
          system: "Persisted"
        })

      :ok = Store.save_tree(store, "s1", %Tree{})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [],
          store: store
        )

      assert Session.get_agent(session, :system) == "Persisted"
    end

    test "persisted :model wins over start opt", ctx do
      store = tmp_store(ctx)

      :ok =
        Store.save_state(store, "s1", %{model: {:anthropic, "claude-sonnet-4-5"}})

      :ok = Store.save_tree(store, "s1", %Tree{})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [model: model()],
          store: store
        )

      agent_model = Session.get_agent(session, :model)
      assert Omni.Model.to_ref(agent_model) == {:anthropic, "claude-sonnet-4-5"}
    end

    test "title is loaded from persisted state", ctx do
      store = tmp_store(ctx)

      :ok =
        Store.save_state(store, "s1", %{
          model: {:anthropic, "claude-haiku-4-5"},
          title: "Kept"
        })

      :ok = Store.save_tree(store, "s1", %Tree{})

      {:ok, session} =
        Session.start_link(
          load: "s1",
          agent: [],
          store: store,
          title: "Ignored"
        )

      assert Session.get_title(session) == "Kept"
    end
  end

  describe "hydration seeding" do
    test "load does not trigger a spurious save_state post-init", ctx do
      inner = tmp_store(ctx)

      :ok = Store.save_state(inner, "s1", %{model: {:anthropic, "claude-haiku-4-5"}})
      :ok = Store.save_tree(inner, "s1", %Tree{})

      # A store that would fail any save_state call — if Session tried
      # to persist during load the failure would surface as a :store
      # event.
      failing_store =
        {Omni.Session.Store.Failing, fail_save_state: :should_not_be_called, delegate: inner}

      {:ok, _session} =
        Session.start_link(
          load: "s1",
          agent: [],
          store: failing_store,
          subscribe: true
        )

      refute_receive {:session, _, :store, {:error, :state, _}}, 200
      refute_receive {:session, _, :store, {:saved, :state}}, 200
    end
  end
end
