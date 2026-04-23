defmodule Omni.Agent.EventsTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Message
  alias Omni.Content.{Text, ToolUse}

  describe ":message event ordering — text-only turn" do
    test "fires for user and assistant, before :step and :turn" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      shape =
        events
        |> Enum.map(fn
          {:message, %Message{role: role}} -> {:message, role}
          {type, _} -> type
        end)
        |> Enum.filter(fn
          # drop streaming deltas/boundaries for a concise trace
          t when t in [:text_start, :text_delta, :text_end] -> false
          :thinking_start -> false
          :thinking_delta -> false
          :thinking_end -> false
          :tool_use_start -> false
          :tool_use_delta -> false
          :tool_use_end -> false
          _ -> true
        end)

      assert shape == [
               :status,
               {:message, :user},
               {:message, :assistant},
               :step,
               :status,
               :turn
             ]
    end

    test ":message payload is a fully-formed Message" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      messages = for {:message, %Message{} = m} <- events, do: m
      assert length(messages) == 2

      [user, assistant] = messages
      assert user.role == :user
      assert [%Text{text: "Hello!"}] = user.content
      assert assistant.role == :assistant
      assert is_list(assistant.content)
    end
  end

  describe ":message event ordering — tool-use turn" do
    test "tool_result events fire before the aggregated user :message" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      shape =
        events
        |> Enum.map(fn
          {:message, %Message{role: role}} -> {:message, role}
          {:tool_result, _} -> :tool_result
          {type, _} -> type
        end)
        |> Enum.filter(fn t -> t in [:tool_result, :step, :turn] or match?({:message, _}, t) end)

      assert shape == [
               {:message, :user},
               {:message, :assistant},
               :step,
               :tool_result,
               {:message, :user},
               {:message, :assistant},
               :step,
               :turn
             ]
    end
  end

  describe ":step response.messages — per-step semantics" do
    test "first step carries the initial user prompt and the assistant response" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      [step_response] = for {:step, resp} <- events, do: resp
      assert length(step_response.messages) == 2
      assert [%Message{role: :user}, %Message{role: :assistant}] = step_response.messages
    end

    test "post-tool step carries preceding tool-result user plus assistant" do
      {:ok, agent} =
        start_agent(
          tools: [tool_with_handler()],
          fixtures: [@tool_use_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "What's the weather?")
      events = collect_events(agent)

      [step1, step2] = for {:step, resp} <- events, do: resp

      # Step 1: initial user prompt + assistant (with tool_use blocks)
      assert length(step1.messages) == 2

      assert [%Message{role: :user}, %Message{role: :assistant, content: content}] =
               step1.messages

      assert Enum.any?(content, &match?(%ToolUse{}, &1))

      # Step 2: tool-result user message + assistant response
      assert length(step2.messages) == 2
      assert [%Message{role: :user}, %Message{role: :assistant}] = step2.messages
    end
  end

  describe ":turn response.messages — per-segment semantics" do
    test "single-segment turn carries the whole segment" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      {:turn, {:stop, resp}} = List.last(events)
      assert length(resp.messages) == 2
      assert [%Message{role: :user}, %Message{role: :assistant}] = resp.messages
    end

    test "continuation turn emits one :turn per segment, each carrying only its own segment" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@text_fixture, @text_fixture, @text_fixture]
        )

      :ok = Agent.prompt(agent, "Start")
      events = collect_events(agent)

      segments = for {:turn, {_variant, resp}} <- events, do: resp.messages
      assert length(segments) == 3

      # Each segment is user + assistant (2 messages), not the cumulative turn
      for segment <- segments do
        assert length(segment) == 2
        assert [%Message{role: :user}, %Message{role: :assistant}] = segment
      end
    end
  end

  describe "segment commit on :turn {:continue, _}" do
    test "state.messages reflects committed segments as the turn progresses" do
      # Serialize observation: each fixture request blocks until we tell it to
      # proceed, so we can inspect state.messages between segments.
      stub_name = unique_stub_name()
      {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

      Req.Test.stub(stub_name, fn conn ->
        Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        body = File.read!(@text_fixture)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, agent} =
        ContinueAgent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Start")

      # Catch each :turn {:continue, _} and check commit
      assert_receive {:agent, ^agent, :turn, {:continue, _}}, 2000
      committed_after_first = Agent.get_state(agent, :messages)
      assert length(committed_after_first) == 2

      assert_receive {:agent, ^agent, :turn, {:continue, _}}, 2000
      committed_after_second = Agent.get_state(agent, :messages)
      assert length(committed_after_second) == 4

      assert_receive {:agent, ^agent, :turn, {:stop, _}}, 2000
      committed_after_stop = Agent.get_state(agent, :messages)
      assert length(committed_after_stop) == 6
    end
  end

  describe "cancel and error do not emit :turn" do
    test "cancel leaves state.messages unchanged" do
      stub_name = unique_stub_name()
      stub_slow(stub_name, @text_fixture, 500)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      before_messages = Agent.get_state(agent, :messages)
      assert before_messages == []

      :ok = Agent.prompt(agent, "Hello!")
      Process.sleep(50)
      :ok = Agent.cancel(agent)

      events = collect_events(agent, 2000)
      refute Enum.any?(events, &match?({:turn, _}, &1))
      assert {:cancelled, _} = List.last(events)
      assert Agent.get_state(agent, :messages) == before_messages
    end

    test "error leaves state.messages unchanged" do
      stub_name = unique_stub_name()
      stub_error(stub_name)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          subscribe: true,
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      refute Enum.any?(events, &match?({:turn, _}, &1))
      assert {:error, _} = List.last(events)
      assert Agent.get_state(agent, :messages) == []
    end
  end

  describe ":state event" do
    test "fires on successful set_state/2 with full new state" do
      {:ok, agent} = start_agent()
      # Drain any startup chatter (no events expected but be safe).
      Process.sleep(10)

      :ok = Agent.set_state(agent, system: "Be concise.")

      assert_receive {:agent, ^agent, :state, %Omni.Agent.State{} = new_state}
      assert new_state.system == "Be concise."
    end

    test "fires on successful set_state/3" do
      {:ok, agent} = start_agent()
      Process.sleep(10)

      :ok = Agent.set_state(agent, :tools, [:fake_tool])

      assert_receive {:agent, ^agent, :state, %Omni.Agent.State{tools: [:fake_tool]}}
    end

    test "emits once per successful call" do
      {:ok, agent} = start_agent()
      Process.sleep(10)

      :ok = Agent.set_state(agent, system: "A")
      :ok = Agent.set_state(agent, system: "B")

      assert_receive {:agent, ^agent, :state, %{system: "A"}}, 500
      assert_receive {:agent, ^agent, :state, %{system: "B"}}, 500
      refute_receive {:agent, ^agent, :state, _}, 100
    end

    test "does not fire on failed set_state (:invalid_messages)" do
      {:ok, agent} = start_agent()
      Process.sleep(10)

      # Ends with a user message — violates the messages invariant.
      bad_messages = [Message.new(role: :user, content: "hi")]

      assert {:error, :invalid_messages} = Agent.set_state(agent, messages: bad_messages)
      refute_receive {:agent, ^agent, :state, _}, 100
    end

    test "does not fire on failed set_state (:invalid_key)" do
      {:ok, agent} = start_agent()
      Process.sleep(10)

      assert {:error, {:invalid_key, :private}} = Agent.set_state(agent, private: %{})
      refute_receive {:agent, ^agent, :state, _}, 100
    end

    test "does not fire on failed set_state/3 (:invalid_key)" do
      {:ok, agent} = start_agent()
      Process.sleep(10)

      assert {:error, {:invalid_key, :status}} = Agent.set_state(agent, :status, :running)
      refute_receive {:agent, ^agent, :state, _}, 100
    end
  end
end
