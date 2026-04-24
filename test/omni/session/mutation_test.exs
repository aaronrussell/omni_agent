defmodule Omni.Session.MutationTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Agent.TestAgents.PauseAgent

  @moduletag :tmp_dir

  describe "set_title/2" do
    test "updates title, emits :title event, persists via save_state", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.set_title(session, "My conversation")

      assert_receive {:session, ^session, :title, "My conversation"}, 1000
      assert_receive {:session, ^session, :store, {:saved, :state}}, 1000

      assert Session.get_title(session) == "My conversation"

      {:ok, _tree, state_map} = Store.load(tmp_store(ctx), "s1")
      assert state_map[:title] == "My conversation"
    end

    test "survives restart via :load", ctx do
      {session, _} = start_session(ctx, new: "s1")
      :ok = Session.set_title(session, "Persisted")
      assert_receive {:session, ^session, :store, {:saved, :state}}, 1000
      :ok = Session.stop(session)

      {:ok, reopened} =
        Session.start_link(
          load: "s1",
          agent: [model: model(), opts: [api_key: "test-key"]],
          store: tmp_store(ctx),
          subscribe: true
        )

      assert Session.get_title(reopened) == "Persisted"
    end

    test "same-value set: no spurious save_state", ctx do
      {session, _} = start_session(ctx, new: "s1", title: "Original")

      :ok = Session.set_title(session, "Original")
      assert_receive {:session, ^session, :title, "Original"}, 500
      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end

    test "nil clears the title", ctx do
      {session, _} = start_session(ctx, new: "s1", title: "Temporary")

      :ok = Session.set_title(session, nil)
      assert_receive {:session, ^session, :title, nil}, 1000

      assert Session.get_title(session) == nil
    end
  end

  describe "add_tool/2 & remove_tool/2" do
    test "add_tool appends to agent's tools and emits :state (no :store)", ctx do
      {session, _} = start_session(ctx, new: "s1")
      assert Session.get_agent(session, :tools) == []

      :ok = Session.add_tool(session, noop_tool())

      assert_receive {:session, ^session, :state, %Omni.Agent.State{tools: [%{name: "noop"}]}},
                     1000

      refute_receive {:session, ^session, :store, {:saved, :state}}, 200
    end

    test "remove_tool by name", ctx do
      tool = noop_tool()
      {session, _} = start_session(ctx, new: "s1", agent_opts: [tools: [tool]])
      assert [%{name: "noop"}] = Session.get_agent(session, :tools)

      :ok = Session.remove_tool(session, "noop")
      assert_receive {:session, ^session, :state, %Omni.Agent.State{tools: []}}, 1000
    end

    test "remove_tool no-ops if name isn't present", ctx do
      {session, _} = start_session(ctx, new: "s1")

      :ok = Session.remove_tool(session, "nonexistent")
      assert Session.get_agent(session, :tools) == []
    end

    test "add_tool during paused turn: returns :paused", ctx do
      {session, _} =
        start_session(ctx,
          agent_module: PauseAgent,
          agent_opts: [tools: [get_weather_tool()]],
          fixture: @tool_use_fixture
        )

      :ok = Session.prompt(session, "Use the tool")
      assert_receive {:session, ^session, :pause, _}, 1000

      assert {:error, :paused} = Session.add_tool(session, noop_tool())
    end
  end

  defp noop_tool do
    Omni.tool(
      name: "noop",
      description: "",
      input_schema: %{type: "object", properties: %{}}
    )
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
