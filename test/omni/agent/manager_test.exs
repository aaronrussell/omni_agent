defmodule Omni.Agent.ManagerTest do
  use ExUnit.Case, async: false

  alias Omni.Agent
  alias Omni.Agent.Manager

  setup do
    start_supervised!(Manager)
    :ok
  end

  defp agent_opts(extra \\ []) do
    Keyword.merge([model: {:anthropic, "claude-haiku-4-5"}], extra)
  end

  describe "supervisor lifecycle" do
    test "Registry and DynamicSupervisor are running under Manager" do
      assert Process.whereis(Omni.Agent.Registry) |> is_pid()
      assert Process.whereis(Omni.Agent.DynamicSupervisor) |> is_pid()
    end
  end

  describe "start_agent/1,2 id resolution" do
    test "uses explicit :id" do
      {:ok, pid} = Manager.start_agent(agent_opts(id: "agent_a"))

      assert Manager.lookup("agent_a") == pid
      assert Agent.get_state(pid, :id) == "agent_a"
    end

    test "auto-generates via Omni.Agent.generate_id when :id omitted" do
      {:ok, pid} = Manager.start_agent(agent_opts())
      id = Agent.get_state(pid, :id)

      assert is_binary(id)
      assert byte_size(id) == 16
      assert Manager.lookup(id) == pid
    end

    test "auto-gen works the same regardless of :store" do
      {:ok, pid1} = Manager.start_agent(agent_opts())
      {:ok, pid2} = Manager.start_agent(agent_opts())

      id1 = Agent.get_state(pid1, :id)
      id2 = Agent.get_state(pid2, :id)

      assert id1 != id2
      assert Manager.lookup(id1) == pid1
      assert Manager.lookup(id2) == pid2
    end

    test "accepts an explicit callback module" do
      defmodule NoopAgent do
        use Omni.Agent
      end

      {:ok, pid} = Manager.start_agent(NoopAgent, agent_opts(id: "a"))
      assert Manager.lookup("a") == pid
    end
  end

  describe "registration collisions" do
    test "second start_agent under same id returns :already_started" do
      {:ok, pid1} = Manager.start_agent(agent_opts(id: "collide"))
      assert {:error, {:already_started, ^pid1}} = Manager.start_agent(agent_opts(id: "collide"))
    end
  end

  describe "lookup/1 and list_running/0" do
    test "lookup returns nil for unknown id" do
      assert Manager.lookup("nonexistent") == nil
    end

    test "list_running reflects currently registered agents" do
      assert Manager.list_running() == []

      {:ok, _} = Manager.start_agent(agent_opts(id: "a"))
      {:ok, _} = Manager.start_agent(agent_opts(id: "b"))

      assert Enum.sort(Manager.list_running()) == ["a", "b"]
    end

    test "list_running excludes stopped agents" do
      {:ok, _} = Manager.start_agent(agent_opts(id: "temp"))
      assert "temp" in Manager.list_running()

      :ok = Manager.stop_agent("temp")
      refute "temp" in Manager.list_running()
    end
  end

  describe "stop_agent/1" do
    test "stops a running agent gracefully" do
      {:ok, pid} = Manager.start_agent(agent_opts(id: "alive"))
      ref = Process.monitor(pid)

      assert :ok = Manager.stop_agent("alive")

      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 500
      # Registry's own DOWN handler runs async; poll briefly for the
      # registration to clear rather than race it.
      assert wait_until(fn -> Manager.lookup("alive") == nil end)
    end

    test "is idempotent for unknown id" do
      assert :ok = Manager.stop_agent("never_started")
    end

    test "is idempotent after the agent has already been stopped" do
      {:ok, _} = Manager.start_agent(agent_opts(id: "x"))
      :ok = Manager.stop_agent("x")
      assert :ok = Manager.stop_agent("x")
    end
  end

  describe "restart: :temporary" do
    test "crashed agents are not auto-restarted" do
      {:ok, pid} = Manager.start_agent(agent_opts(id: "crashy"))
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

      # Registry auto-cleans on DOWN; the id is free for a fresh start.
      assert wait_until(fn -> Manager.lookup("crashy") == nil end)
      refute "crashy" in Manager.list_running()
    end
  end

  defp wait_until(fun, timeout \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        true
      else
        Process.sleep(5)
        false
      end
    end)
    |> Enum.find(fn ok? -> ok? or System.monotonic_time(:millisecond) > deadline end)
  end
end
