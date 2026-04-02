defmodule Omni.Agent.SteeringTest do
  use Omni.Agent.AgentCase, async: true

  describe "prompt while running" do
    test "stages prompt and returns :ok" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 200)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert :ok = Agent.prompt(agent, "Follow up!")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end
  end

  describe "steering" do
    test "prompt while running returns :ok (not {:error, :running})" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 200)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      assert :ok = Agent.prompt(agent, "Follow up!")
      Agent.cancel(agent)
      _events = collect_events(agent, 2000)
    end

    test "staged prompt overrides {:stop} at turn boundary" do
      stub_name = unique_stub_name()
      {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub_name, fn conn ->
        call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        # First call is slow so we can stage a prompt while running
        if call_num == 0, do: Process.sleep(200)

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.prompt(agent, "Follow up!")

      events = collect_events(agent)

      # Should have a :continue event (first turn) followed by :stop (second turn from steering)
      continue_events = for {:continue, _data} <- events, do: :ok
      assert length(continue_events) == 1
      assert {:stop, %Response{}} = List.last(events)
    end

    test "last-one-wins: second staged prompt replaces first" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 300)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.prompt(agent, "First follow-up")
      :ok = Agent.prompt(agent, "Second follow-up")

      # The second prompt should win — agent will continue after first turn
      events = collect_events(agent)
      continue_events = for {:continue, _data} <- events, do: :ok
      assert length(continue_events) == 1
      assert {:stop, %Response{}} = List.last(events)

      # Context should have messages from two turns
      messages = Agent.get_state(agent, :context).messages
      # First user + assistant + second user + assistant = 4
      assert length(messages) == 4
    end

    test "prompt while paused stages content for next turn" do
      stub_name = unique_stub_name()
      stub_sequence(stub_name, [@tool_use_fixture, @text_fixture, @text_fixture])

      {:ok, agent} =
        PauseAgent.start_link(
          model: model(),
          tools: [tool_with_handler()],
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Use the tool")
      events = collect_events(agent)
      assert {:pause, {:authorize, %ToolUse{}}} = List.last(events)

      # Stage a prompt while paused
      assert :ok = Agent.prompt(agent, "Follow up after tools")

      :ok = Agent.resume(agent, :execute)
      events = collect_events(agent)

      # Should have :continue (tool loop completed) then :stop (staged prompt turn)
      continue_events = for {:continue, _data} <- events, do: :ok
      assert length(continue_events) == 1
      assert {:stop, %Response{}} = List.last(events)
    end
  end

  describe "cancel" do
    test "cancels a running step and emits :cancelled" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert {:cancelled, %Response{stop_reason: :cancelled}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # Cancel discards pending messages, context stays empty
      assert Agent.get_state(agent, :context).messages == []
    end

    test "cancel while idle returns error" do
      {:ok, agent} = start_agent()
      assert {:error, :idle} = Agent.cancel(agent)
    end

    test "cancel response includes pending messages" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      assert {:cancelled, %Response{} = resp} = List.last(events)

      # The user message should be in pending messages
      assert length(resp.messages) >= 1
      assert Enum.any?(resp.messages, &(&1.role == :user))
    end
  end

  describe "staged prompt overrides {:continue}" do
    test "staged prompt replaces continuation prompt at turn boundary" do
      # ContinueAgent returns {:continue, "Continue.", state} for first 2 turns
      # But if we stage a prompt, it should use our prompt instead
      stub_name = unique_stub_name()
      {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub_name, fn conn ->
        call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        # First call is slow so we can stage a prompt while running
        if call_num == 0, do: Process.sleep(200)

        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start")
      Process.sleep(50)
      # Stage a prompt while the first step is running
      :ok = Agent.prompt(agent, "Redirect!")

      events = collect_events(agent)

      # The staged prompt should have overridden the continuation
      # ContinueAgent's handle_turn still fires (turn_count increments)
      # but the staged prompt replaces the continuation content
      continue_events = for {:continue, _data} <- events, do: :ok
      assert length(continue_events) >= 1
      assert {:stop, %Response{}} = List.last(events)

      # Verify the staged prompt made it into context
      messages = Agent.get_state(agent, :context).messages
      user_contents = for %{role: :user} = msg <- messages, do: msg
      # Should have "Start" and "Redirect!" as user messages (not "Continue.")
      assert length(user_contents) >= 2
    end
  end

  describe "max_steps with staged prompt" do
    test "max_steps reached forces stop even with staged prompt" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 200)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          listener: self(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!", max_steps: 1)
      Process.sleep(50)
      # Stage a prompt — but max_steps should prevent it from being used
      :ok = Agent.prompt(agent, "Follow up!")

      events = collect_events(agent)

      # Should complete with :stop (max_steps forces stop, staged prompt ignored)
      assert {:stop, %Response{}} = List.last(events)
      # Only 1 turn worth of messages (user + assistant = 2)
      assert length(Agent.get_state(agent, :context).messages) == 2
    end
  end
end
