defmodule Omni.Agent.StateTest do
  use Omni.Agent.AgentCase, async: true

  describe "get_state" do
    test "returns the full state struct" do
      {:ok, agent} = start_agent()
      state = Agent.get_state(agent)
      assert %Omni.Agent.State{} = state
      assert %Omni.Model{id: "claude-haiku-4-5"} = state.model
      assert state.status == :idle
      assert state.private == %{}
      assert state.meta == %{}
    end

    test "returns individual fields by key" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_state(agent, :model)
      assert %Context{} = Agent.get_state(agent, :context)
      assert Agent.get_state(agent, :context).tools == []
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :private) == %{}
    end

    test "returns nil for unknown keys" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :nonexistent) == nil
    end
  end

  describe "set_state/2" do
    test "replaces context" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :context).system == nil

      ctx = Agent.get_state(agent, :context)
      :ok = Agent.set_state(agent, context: %{ctx | system: "Be helpful."})
      assert Agent.get_state(agent, :context).system == "Be helpful."
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

    test "rejects old keys that are no longer settable" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :system}} = Agent.set_state(agent, system: "New")
      assert {:error, {:invalid_key, :tools}} = Agent.set_state(agent, tools: [])
    end

    test "atomic — bad model rejects all changes" do
      {:ok, agent} = start_agent()
      original_ctx = Agent.get_state(agent, :context)

      result = Agent.set_state(agent, model: {:anthropic, "nonexistent"}, context: %Context{})
      assert {:error, {:model_not_found, _}} = result
      # Context should not have changed
      assert Agent.get_state(agent, :context) == original_ctx
    end

    test "returns error when running" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert {:error, :running} = Agent.set_state(agent, context: %Context{})
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "set_state/3" do
    test "replaces field with value" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :context, %Context{system: "New system"})
      assert Agent.get_state(agent, :context).system == "New system"
    end

    test "transforms field with function" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :opts, fn opts -> Keyword.put(opts, :temperature, 0.7) end)
      assert Keyword.get(Agent.get_state(agent, :opts), :temperature) == 0.7
    end

    test "transforms context with function" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :context, fn ctx -> %{ctx | system: "Updated"} end)
      assert Agent.get_state(agent, :context).system == "Updated"
    end

    test "rejects non-settable field" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :status}} = Agent.set_state(agent, :status, :running)
    end

    test "rejects non-settable field private" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :private}} = Agent.set_state(agent, :private, %{})
    end
  end

  describe "messages: at start_link" do
    test "accepts pre-built messages list" do
      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")

      {:ok, agent} =
        start_agent(messages: [user_msg, asst_msg])

      assert length(Agent.get_state(agent, :context).messages) == 2
    end

    test "prompt builds on existing messages" do
      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")

      {:ok, agent} =
        start_agent(messages: [user_msg, asst_msg])

      :ok = Agent.prompt(agent, "Follow up")
      _events = collect_events(agent)

      # 2 original + 2 new (user + assistant)
      assert length(Agent.get_state(agent, :context).messages) == 4
    end

    test "accepts context struct" do
      user_msg = Omni.Message.new(role: :user, content: "Hello")
      asst_msg = Omni.Message.new(role: :assistant, content: "Hi there")

      context = %Context{
        system: "You are helpful.",
        messages: [user_msg, asst_msg],
        tools: []
      }

      {:ok, agent} =
        start_agent(context: context)

      assert Agent.get_state(agent, :context).system == "You are helpful."
      assert length(Agent.get_state(agent, :context).messages) == 2
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

  describe "listen/2" do
    test "returns error when running" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert {:error, :running} = Agent.listen(agent, self())
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end

    test "returns error when paused" do
      {:ok, agent} =
        start_agent_with_module(PauseAgent,
          tools: [tool_with_handler()],
          fixture: @tool_use_fixture,
          listener: self()
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      assert {:error, :running} = Agent.listen(agent, self())

      # Clean up
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
