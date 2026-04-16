defmodule Omni.Agent.PromptTest do
  use Omni.Agent.AgentCase, async: true

  describe "basic prompt/response" do
    test "streams text events and emits :stop with a valid response" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")

      events = collect_events(agent)
      text_events = for {:text_delta, _data} <- events, do: :ok
      assert length(text_events) > 0
      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
    end
  end

  describe "turn events" do
    test "turn event has response with correct data" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:stop, %Response{} = resp} = List.last(events)
      assert length(resp.messages) > 0
      assert resp.usage.total_tokens > 0
    end

    test "second prompt produces response with messages" do
      {:ok, agent} =
        start_agent(fixtures: [@text_fixture, @text_fixture])

      :ok = Agent.prompt(agent, "First")
      _events = collect_events(agent)

      :ok = Agent.prompt(agent, "Second")
      events = collect_events(agent)

      assert {:stop, %Response{}} = List.last(events)

      # After two turns, tree should have 4 messages
      assert length(Agent.get_state(agent, :tree)) == 4
    end
  end

  describe "custom handle_turn callback" do
    test "handle_turn can modify private" do
      {:ok, agent} = start_agent_with_module(CustomTurn, [])

      :ok = Agent.prompt(agent, "Hello!")
      _events = collect_events(agent)

      assert Agent.get_state(agent, :private).last_stop_reason == :stop
    end
  end

  describe "conversation context builds up" do
    test "messages accumulate across prompts" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "First message")
      _events = collect_events(agent)

      messages = Agent.get_state(agent, :tree)
      assert length(messages) == 2

      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent2} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent2)

      :ok = Agent.prompt(agent2, "First")
      _events = collect_events(agent2)
      assert length(Agent.get_state(agent2, :tree)) == 2

      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent2, "Second")
      _events = collect_events(agent2)
      assert length(Agent.get_state(agent2, :tree)) == 4
    end
  end

  describe "prompt with content blocks" do
    test "accepts list of content blocks" do
      {:ok, agent} = start_agent()

      content = [Text.new("Hello!"), Text.new("How are you?")]
      :ok = Agent.prompt(agent, content)
      events = collect_events(agent)

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
      messages = Agent.get_state(agent, :tree)
      assert length(messages) == 2

      [user_msg | _] = messages
      assert user_msg.role == :user
      assert length(user_msg.content) == 2
    end
  end

  describe "turn response content" do
    test "contains expected user and assistant messages" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:stop, %Response{} = resp} = List.last(events)
      assert length(resp.messages) == 2

      [user_msg, assistant_msg] = resp.messages
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end
  end

  describe "streaming events" do
    test "includes text_start and text_end events" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      event_types = Enum.map(events, &elem(&1, 0))
      assert :text_start in event_types
      assert :text_end in event_types
      assert :text_delta in event_types
    end

    test "thinking events pass through to subscriber" do
      {:ok, agent} = start_agent(fixture: @thinking_fixture)

      :ok = Agent.prompt(agent, "Think about this")
      events = collect_events(agent)

      event_types = Enum.map(events, &elem(&1, 0))
      assert :thinking_start in event_types
      assert :thinking_delta in event_types
      assert :thinking_end in event_types
      assert {:stop, %Response{}} = List.last(events)
    end
  end
end
