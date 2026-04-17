defmodule Omni.Agent.StateTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Message
  alias Omni.Content.{Text, ToolUse}

  describe "get_state" do
    test "returns the full state struct" do
      {:ok, agent} = start_agent()
      state = Agent.get_state(agent)
      assert %Omni.Agent.State{} = state
      assert %Omni.Model{id: "claude-haiku-4-5"} = state.model
      assert state.status == :idle
      assert state.private == %{}
      assert state.system == nil
      assert state.messages == []
      assert state.tools == []
    end

    test "returns individual fields by key" do
      {:ok, agent} = start_agent()
      assert %Omni.Model{id: "claude-haiku-4-5"} = Agent.get_state(agent, :model)
      assert Agent.get_state(agent, :system) == nil
      assert Agent.get_state(agent, :messages) == []
      assert Agent.get_state(agent, :tools) == []
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :private) == %{}
    end

    test "returns nil for unknown keys" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :nonexistent) == nil
    end
  end

  describe "set_state/2" do
    test "replaces system prompt" do
      {:ok, agent} = start_agent()
      assert Agent.get_state(agent, :system) == nil

      :ok = Agent.set_state(agent, system: "Be helpful.")
      assert Agent.get_state(agent, :system) == "Be helpful."
    end

    test "replaces tools" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_state(agent, tools: [:fake_tool])
      assert Agent.get_state(agent, :tools) == [:fake_tool]
    end

    test "replaces opts (full replacement, not merge)" do
      {:ok, agent} = start_agent()
      original_opts = Agent.get_state(agent, :opts)
      assert Keyword.has_key?(original_opts, :api_key)

      :ok = Agent.set_state(agent, opts: [temperature: 0.7])
      new_opts = Agent.get_state(agent, :opts)
      assert new_opts == [temperature: 0.7]
      refute Keyword.has_key?(new_opts, :api_key)
    end

    test "rejects invalid keys" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :status}} = Agent.set_state(agent, status: :running)
    end

    test "rejects removed keys" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_key, :context}} = Agent.set_state(agent, context: %{})
      assert {:error, {:invalid_key, :meta}} = Agent.set_state(agent, meta: %{})
      assert {:error, {:invalid_key, :private}} = Agent.set_state(agent, private: %{})
    end

    test "atomic — bad model rejects all changes" do
      {:ok, agent} = start_agent()
      original_system = Agent.get_state(agent, :system)

      result = Agent.set_state(agent, model: {:anthropic, "nonexistent"}, system: "new")
      assert {:error, {:model_not_found, _}} = result

      assert Agent.get_state(agent, :system) == original_system
    end

    test "atomic — invalid messages rejects all changes" do
      {:ok, agent} = start_agent()
      original_system = Agent.get_state(agent, :system)

      bad = [Message.new(role: :user, content: "dangling")]

      assert {:error, :invalid_messages} =
               Agent.set_state(agent, system: "new", messages: bad)

      assert Agent.get_state(agent, :system) == original_system
      assert Agent.get_state(agent, :messages) == []
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
      assert {:error, :running} = Agent.set_state(agent, system: "new")
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

    test "transforms tools with function" do
      {:ok, agent} = start_agent()
      :ok = Agent.set_state(agent, :tools, fn tools -> [:new | tools] end)
      assert Agent.get_state(agent, :tools) == [:new]
    end

    test "rejects non-settable field status" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :status}} = Agent.set_state(agent, :status, :running)
    end

    test "rejects non-settable field private" do
      {:ok, agent} = start_agent()
      assert {:error, {:invalid_field, :private}} = Agent.set_state(agent, :private, %{})
    end
  end

  describe "set_state(:messages, ...) validation" do
    setup do
      {:ok, agent} = start_agent()
      %{agent: agent}
    end

    test "accepts empty list", %{agent: agent} do
      :ok = Agent.set_state(agent, :messages, [])
      assert Agent.get_state(agent, :messages) == []
    end

    test "accepts list ending in assistant message with no ToolUse blocks", %{agent: agent} do
      messages = [
        Message.new(role: :user, content: "Hello"),
        Message.new(role: :assistant, content: [Text.new("Hi there")])
      ]

      :ok = Agent.set_state(agent, :messages, messages)
      assert Agent.get_state(agent, :messages) == messages
    end

    test "rejects list ending in user message", %{agent: agent} do
      messages = [Message.new(role: :user, content: "Dangling")]
      assert {:error, :invalid_messages} = Agent.set_state(agent, :messages, messages)
      assert Agent.get_state(agent, :messages) == []
    end

    test "rejects list ending in assistant message with ToolUse blocks", %{agent: agent} do
      tool_use = %ToolUse{id: "t1", name: "search", input: %{}}

      messages = [
        Message.new(role: :user, content: "search"),
        Message.new(role: :assistant, content: [Text.new("sure"), tool_use])
      ]

      assert {:error, :invalid_messages} = Agent.set_state(agent, :messages, messages)
      assert Agent.get_state(agent, :messages) == []
    end

    test "rejects via keyword form too", %{agent: agent} do
      messages = [Message.new(role: :user, content: "Dangling")]
      assert {:error, :invalid_messages} = Agent.set_state(agent, messages: messages)
    end
  end

  describe "messages: at start_link" do
    test "accepts pre-built messages list" do
      user_msg = Message.new(role: :user, content: "Hello")
      asst_msg = Message.new(role: :assistant, content: [Text.new("Hi there")])

      {:ok, agent} =
        start_agent(messages: [user_msg, asst_msg])

      assert length(Agent.get_state(agent, :messages)) == 2
    end

    test "prompt builds on existing messages" do
      user_msg = Message.new(role: :user, content: "Hello")
      asst_msg = Message.new(role: :assistant, content: [Text.new("Hi there")])

      {:ok, agent} =
        start_agent(messages: [user_msg, asst_msg])

      :ok = Agent.prompt(agent, "Follow up")
      _events = collect_events(agent)

      # 2 original + 2 new (user + assistant)
      assert length(Agent.get_state(agent, :messages)) == 4
    end

    test "accepts system + messages + tools at start_link" do
      user_msg = Message.new(role: :user, content: "Hello")
      asst_msg = Message.new(role: :assistant, content: [Text.new("Hi there")])

      {:ok, agent} =
        start_agent(
          system: "You are helpful.",
          messages: [user_msg, asst_msg],
          tools: []
        )

      assert Agent.get_state(agent, :system) == "You are helpful."
      assert length(Agent.get_state(agent, :messages)) == 2
      assert Agent.get_state(agent, :tools) == []
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

      assert {:error, :running} = Agent.set_state(agent, system: "new")

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
