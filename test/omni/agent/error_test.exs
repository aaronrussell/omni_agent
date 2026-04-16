defmodule Omni.Agent.ErrorTest do
  use Omni.Agent.AgentCase, async: true

  describe "handle_error" do
    test "default handle_error stops with :error event on step failure" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:error, _reason} = List.last(events)
      # Agent goes to :idle (not :error) — pending messages discarded
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :tree) == []
    end

    test "custom {:retry, state} retries and succeeds on second attempt" do
      stub_name = unique_stub_name()
      stub_error_then_success(stub_name, @text_fixture)

      {:ok, agent} =
        ErrorRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
      assert Agent.get_state(agent, :private).retries == 1
    end

    test "retry exhaustion still emits :error" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        ErrorRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # After retrying once and failing again, should emit :error
      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :private).retries == 1
    end
  end

  describe "step crash handling" do
    test "step crash triggers handle_error with {:step_crashed, reason}" do
      stub_name = unique_stub_name()
      test_pid = self()

      # Hang the plug so the step stays alive while we crash it
      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, :step_started)
        Process.sleep(:infinity)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end)

      {:ok, agent} =
        CrashRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive :step_started, 2000

      server = :sys.get_state(agent)
      {step_pid, _ref} = server.step_task
      Process.exit(step_pid, :test_crash)

      # handle_error returns {:retry, state} — agent retries then hangs again
      assert_receive {:agent, ^agent, :retry, {:step_crashed, :test_crash}}, 2000
    end

    test "executor crash emits :error with {:executor_crashed, reason}" do
      stub_name = unique_stub_name()

      # Step completes with tool_use, then executor runs the hanging tool
      stub_fixture(stub_name, @tool_use_fixture)

      hanging_tool =
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> Process.sleep(:infinity) end
        )

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          tools: [hanging_tool],
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "What's the weather?")

      # Wait for step to complete and executor to spawn
      Process.sleep(200)

      server = :sys.get_state(agent)
      assert {executor_pid, _ref} = server.executor_task
      Process.exit(executor_pid, :test_crash)

      assert_receive {:agent, ^agent, :error, {:executor_crashed, :test_crash}}, 2000
    end

    test "step crash with default handle_error emits :error" do
      stub_name = unique_stub_name()
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, :step_started)
        Process.sleep(:infinity)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "")
      end)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      assert_receive :step_started, 2000

      server = :sys.get_state(agent)
      {step_pid, _ref} = server.step_task
      Process.exit(step_pid, :test_crash)

      # Default handle_error returns {:stop, state} — agent emits :error
      assert_receive {:agent, ^agent, :error, {:step_crashed, :test_crash}}, 2000
    end
  end

  describe "error discards pending messages" do
    test "context stays clean after error" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:error, _reason} = List.last(events)

      # Agent is idle, context messages are empty (user msg was discarded)
      assert Agent.get_state(agent, :status) == :idle
      assert Agent.get_state(agent, :tree) == []
    end

    test "can prompt again after error" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)
      assert {:error, _reason} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle

      # Prompt again with a working stub
      stub_fixture(stub_name, @text_fixture)
      :ok = Agent.prompt(agent, "Try again!")
      events = collect_events(agent)

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)
      assert Agent.get_state(agent, :status) == :idle
      # Only the successful turn's messages
      assert length(Agent.get_state(agent, :tree)) == 2
    end
  end

  describe "retry preserves pending messages" do
    test "context stays empty during retry, committed on success" do
      stub_name = unique_stub_name()
      stub_error_then_success(stub_name, @text_fixture)

      {:ok, agent} =
        ErrorRetryAgent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      {:ok, _} = Agent.subscribe(agent)

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      # Should have a :retry event followed by :stop
      retry_events = for {:retry, _data} <- events, do: :ok
      assert length(retry_events) == 1

      assert {:stop, %Response{stop_reason: :stop}} = List.last(events)

      # Context should have committed messages from the successful turn
      messages = Agent.get_state(agent, :tree)
      assert length(messages) == 2

      [user_msg, assistant_msg] = messages
      assert user_msg.role == :user
      assert assistant_msg.role == :assistant
    end
  end
end
