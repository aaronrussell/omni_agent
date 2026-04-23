defmodule Omni.Agent.LifecycleTest do
  use Omni.Agent.AgentCase, async: true

  describe "custom init callback" do
    test "init sets private" do
      {:ok, agent} =
        start_agent_with_module(WithInit, private: %{agent_name: "test-bot"})

      assert Agent.get_state(agent, :private) == %{agent_name: "test-bot", name: "test-bot"}
    end

    test "init with default name" do
      {:ok, agent} = start_agent_with_module(WithInit, [])

      assert Agent.get_state(agent, :private) == %{name: "default"}
    end

    test "init receives fully-resolved state" do
      defmodule CaptureState do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          send(state.private.test_pid, {:init_state, state})
          {:ok, state}
        end
      end

      {:ok, _agent} =
        start_agent_with_module(
          CaptureState,
          system: "hello",
          tools: [],
          private: %{test_pid: self()}
        )

      assert_receive {:init_state, %Omni.Agent.State{} = state}
      assert state.system == "hello"
      assert state.messages == []
      assert state.tools == []
      assert state.private.test_pid == self()
    end

    test "init can mutate any state field" do
      defmodule MutateAll do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          {:ok, %{state | system: "mutated", tools: [:fake_tool]}}
        end
      end

      {:ok, agent} = start_agent_with_module(MutateAll, [])

      assert Agent.get_state(agent, :system) == "mutated"
      assert Agent.get_state(agent, :tools) == [:fake_tool]
    end

    test "init returning invalid messages fails start_link" do
      defmodule BadInit do
        use Omni.Agent

        @impl Omni.Agent
        def init(state) do
          bad = [Omni.Message.new(role: :user, content: "dangling user")]
          {:ok, %{state | messages: bad}}
        end
      end

      Process.flag(:trap_exit, true)

      assert {:error, :invalid_messages} =
               BadInit.start_link(
                 model: model(),
                 opts: [api_key: "test-key"]
               )
    end
  end

  describe "init error" do
    test "start_link fails when init returns error" do
      Process.flag(:trap_exit, true)

      assert {:error, :bad_config} =
               FailInit.start_link(
                 model: model(),
                 opts: [api_key: "test-key"]
               )
    end

    test "start_link fails when model is nil" do
      Process.flag(:trap_exit, true)

      assert {:error, :missing_model} =
               WithInit.start_link(opts: [api_key: "test-key"])
    end
  end

  describe "terminate callback" do
    test "terminate/2 is called on normal shutdown" do
      {:ok, agent} =
        start_agent_with_module(TerminateAgent, private: %{test_pid: self()})

      Process.unlink(agent)
      GenServer.stop(agent, :normal)
      assert_receive {:terminated, :normal}, 1000
    end

    test "terminate/2 receives shutdown reason" do
      {:ok, agent} =
        start_agent_with_module(TerminateAgent, private: %{test_pid: self()})

      Process.unlink(agent)
      GenServer.stop(agent, :shutdown)
      assert_receive {:terminated, :shutdown}, 1000
    end
  end

  describe "named agent" do
    test "can be called by name" do
      name = :"agent_named_#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        start_agent(name: name)

      assert Agent.get_state(name, :status) == :idle
      assert %Omni.Model{} = Agent.get_state(name, :model)
    end
  end

  describe "use macro start_link/1" do
    test "generated start_link works" do
      {:ok, agent} = start_agent_with_module(WithInit, [])

      assert is_pid(agent)
      assert Agent.get_state(agent, :private) == %{name: "default"}
    end
  end

  describe "system prompt" do
    test "system prompt is set from opts" do
      {:ok, agent} =
        start_agent(system: "You are a helpful assistant.")

      assert Agent.get_state(agent, :system) == "You are a helpful assistant."
    end
  end

  describe "private defaults" do
    test "private defaults to empty map without init callback" do
      {:ok, agent} = start_agent()

      assert Agent.get_state(agent, :private) == %{}
    end

    test "init callback sets private state" do
      {:ok, agent} =
        start_agent_with_module(TerminateAgent, private: %{test_pid: self()})

      assert Agent.get_state(agent, :private) == %{test_pid: self()}
    end
  end

  describe "no subscribers" do
    test "agent completes without crashing when nobody is subscribed" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      :ok = Agent.prompt(agent, "Hello!")

      # No subscribers — events go nowhere. Poll status to detect the
      # transition back to :idle once the turn completes.
      deadline = System.monotonic_time(:millisecond) + 2000

      wait_idle = fn wait_idle ->
        cond do
          Agent.get_state(agent, :status) == :idle and
              length(Agent.get_state(agent, :messages)) == 2 ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("agent did not return to :idle within 2000ms")

          true ->
            Process.sleep(10)
            wait_idle.(wait_idle)
        end
      end

      :ok = wait_idle.(wait_idle)

      # No :agent messages should have been delivered to the test mailbox.
      refute_receive {:agent, ^agent, _type, _data}, 50
    end
  end
end
