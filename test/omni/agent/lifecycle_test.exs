defmodule Omni.Agent.LifecycleTest do
  use OmniAgent.AgentCase, async: true

  describe "custom init callback" do
    test "init sets private" do
      {:ok, agent} =
        start_agent_with_module(WithInit, agent_name: "test-bot")

      assert Agent.get_state(agent, :private) == %{name: "test-bot"}
    end

    test "init with default name" do
      {:ok, agent} = start_agent_with_module(WithInit, [])

      assert Agent.get_state(agent, :private) == %{name: "default"}
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

      assert Agent.get_state(agent, :context).system == "You are a helpful assistant."
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

  describe "no listener" do
    test "agent completes without crashing when no listener is set" do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, agent} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}]
        )

      # Prompt without being the listener (pass a different listener)
      # Actually, prompt/3 auto-sets caller as listener, so start a separate process
      test_pid = self()

      spawn(fn ->
        :ok = Agent.prompt(agent, "Hello!")
        send(test_pid, :prompted)
      end)

      assert_receive :prompted, 1000
      # Give it time to finish the turn
      Process.sleep(500)
      assert Agent.get_state(agent, :status) == :idle
      # Context should have committed messages
      assert length(Agent.get_state(agent, :context).messages) == 2
    end
  end
end
