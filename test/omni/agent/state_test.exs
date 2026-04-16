defmodule Omni.Agent.StateTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent.Tree

  describe "get_state" do
    test "returns the full state struct" do
      {:ok, agent} = start_agent()
      state = Agent.get_state(agent)
      assert %Omni.Agent.State{} = state
      assert %Omni.Model{id: "claude-haiku-4-5"} = state.model
      assert state.status == :idle
      assert state.private == %{}
      assert state.meta == %{}
      assert state.tree == %Tree{}
      assert state.tools == []
      assert state.system == nil
      assert state.id == nil
    end

    test "returns individual fields by key" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_state(agent, :model)
      assert Agent.get_state(agent, :tree) == %Tree{}
      assert Agent.get_state(agent, :tools) == []
      assert Agent.get_state(agent, :system) == nil
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :private) == %{}
    end

    test "returns nil for unknown keys" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :nonexistent) == nil
    end
  end

  describe "set_state/2" do
    test "replaces system" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :system) == nil

      :ok = Agent.set_state(agent, system: "Be helpful.")
      assert Agent.get_state(agent, :system) == "Be helpful."
    end

    test "replaces tools" do
      tool = tool_with_handler()
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :tools) == []

      :ok = Agent.set_state(agent, tools: [tool])
      assert [^tool] = Agent.get_state(agent, :tools)
    end

    test "replaces opts (full replacement, not merge)" do
      {:ok, agent} = start_agent()
      # Original opts include api_key and plug
      original_opts = Agent.get_state(agent, :opts)
      assert Keyword.has_key?(original_opts, :api_key)

      :ok = Agent.set_state(agent, opts: [temperature: 0.7])
      new_opts = Agent.get_state(agent, :opts)
      assert new_opts == [temperature: 0.7]
      refute Keyword.has_key?(new_opts, :api_key)
    end

    test "replaces meta (full replacement, not merge)" do
      {:ok, agent} = start_agent(meta: %{a: 1})
      assert Agent.get_state(agent, :meta) == %{a: 1}

      :ok = Agent.set_state(agent, meta: %{b: 2})
      assert Agent.get_state(agent, :meta) == %{b: 2}
    end

    test "rejects invalid keys" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :status}} = Agent.set_state(agent, status: :running)
    end

    test "rejects legacy :context key" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :context}} = Agent.set_state(agent, context: %Context{})
    end

    test "atomic — bad model rejects all changes" do
      {:ok, agent} = start_agent()
      original_system = Agent.get_state(agent, :system)

      result = Agent.set_state(agent, model: {:anthropic, "nonexistent"}, system: "Changed")
      assert {:error, {:model_not_found, _}} = result
      # System should not have changed
      assert Agent.get_state(agent, :system) == original_system
    end

    test "returns error when running" do
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
      assert {:error, :running} = Agent.set_state(agent, system: "Changed")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "set_state/3" do
    test "replaces field with value" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :system, "New system")
      assert Agent.get_state(agent, :system) == "New system"
    end

    test "transforms field with function" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :opts, fn opts -> Keyword.put(opts, :temperature, 0.7) end)
      assert Keyword.get(Agent.get_state(agent, :opts), :temperature) == 0.7
    end

    test "transforms meta with function" do
      {:ok, agent} = start_agent(meta: %{count: 1})
      :ok = Agent.set_state(agent, :meta, fn meta -> Map.put(meta, :count, meta.count + 1) end)
      assert Agent.get_state(agent, :meta) == %{count: 2}
    end

    test "rejects non-settable field" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :status}} = Agent.set_state(agent, :status, :running)
    end

    test "rejects non-settable field private" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :private}} = Agent.set_state(agent, :private, %{})
    end

    test "rejects non-settable field tree" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :tree}} = Agent.set_state(agent, :tree, %Tree{})
    end
  end

  describe "tree: at start_link" do
    test "accepts pre-built tree struct" do
      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")

      tree =
        %Tree{}
        |> Tree.push(user_msg)
        |> Tree.push(asst_msg)

      {:ok, agent} = start_agent(tree: tree)

      assert Tree.size(Agent.get_state(agent, :tree)) == 2
    end

    test "prompt builds on existing tree" do
      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")

      tree =
        %Tree{}
        |> Tree.push(user_msg)
        |> Tree.push(asst_msg)

      {:ok, agent} = start_agent(tree: tree)

      :ok = Agent.prompt(agent, "Follow up")
      _events = collect_events(agent)

      # 2 original + 2 new (user + assistant)
      assert Tree.size(Agent.get_state(agent, :tree)) == 4
    end

    test "rejects legacy :context start opt" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_opt, :context}} =
               Agent.start_link(
                 model: model(),
                 context: %Context{system: "Hello"},
                 opts: [api_key: "test-key"]
               )
    end

    test "rejects legacy :listener start opt" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_opt, :listener}} =
               Agent.start_link(
                 model: model(),
                 listener: self(),
                 opts: [api_key: "test-key"]
               )
    end

    test "rejects legacy :messages start opt" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_opt, :messages}} =
               Agent.start_link(
                 model: model(),
                 messages: [],
                 opts: [api_key: "test-key"]
               )
    end
  end

  describe "set_state when paused" do
    test "returns error when paused" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      assert {:error, :running} = Agent.set_state(agent, meta: %{test: true})

      # Clean up
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "subscribe/1 errors" do
    test "subscribe is always allowed (even while running)" do
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

      # A second subscribe from the same pid is idempotent and still succeeds.
      assert {:ok, %Omni.Agent.Snapshot{status: :running}} = Agent.subscribe(agent)

      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "step counter" do
    test "resets to 0 after turn completes" do
      {:ok, agent} = start_agent()

      assert Agent.get_state(agent, :step) == 0

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      assert Agent.get_state(agent, :step) == 0
      assert Agent.get_state(agent, :status) == :idle
    end
  end
end
