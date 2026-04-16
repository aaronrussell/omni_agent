defmodule Omni.Agent.IdleTimerTest do
  use Omni.Agent.AgentCase, async: false

  alias Omni.Agent
  alias Omni.Agent.Manager
  alias Omni.Agent.Store.FileSystem

  @timeout 50

  setup do
    start_supervised!(Manager)
    :ok
  end

  # Start a Manager-supervised agent with an SSE stub. Optionally subscribe
  # the test process. Returns {pid, id}.
  defp start_supervised_agent(extra \\ []) do
    stub_name = :"idle_test_#{System.unique_integer([:positive])}"

    fixture =
      Keyword.get(extra, :fixture, "test/support/fixtures/sse/anthropic_text.sse")

    delay = Keyword.get(extra, :slow)

    if delay do
      stub_slow(stub_name, fixture, delay)
    else
      stub_fixture(stub_name, fixture)
    end

    opts =
      Keyword.merge(
        [
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}],
          idle_timeout: @timeout
        ],
        Keyword.drop(extra, [:slow, :fixture, :subscribe])
      )

    {:ok, pid} = Manager.start_agent(opts)

    # Agent is spawned by DynamicSupervisor — its $callers chain does not
    # include the test pid, so Req.Test stubs registered against self()
    # aren't reachable without an explicit allow.
    Req.Test.allow(stub_name, self(), pid)

    if Keyword.get(extra, :subscribe, false) do
      {:ok, _} = Agent.subscribe(pid)
    end

    id = Agent.get_state(pid, :id)
    {pid, id}
  end

  defp wait_until_dead(pid, timeout) do
    ref = Process.monitor(pid)
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:ok, reason}
    after
      timeout -> :still_alive
    end
  end

  describe "timer arms when idle and unobserved" do
    test "agent terminates after the timeout" do
      {pid, _id} = start_supervised_agent()

      assert {:ok, :normal} = wait_until_dead(pid, @timeout * 4)
    end
  end

  describe "timer cancels on subscribe" do
    test "subscribed agent survives past the timeout" do
      {pid, _id} = start_supervised_agent(subscribe: true)

      Process.sleep(@timeout * 3)

      assert Process.alive?(pid)
    end

    test "agent re-arms after unsubscribe" do
      {pid, _id} = start_supervised_agent(subscribe: true)

      Process.sleep(@timeout * 3)
      assert Process.alive?(pid)

      :ok = Agent.unsubscribe(pid)

      assert {:ok, :normal} = wait_until_dead(pid, @timeout * 4)
    end
  end

  describe "timer cancels on prompt" do
    test "agent survives while running" do
      {pid, _id} = start_supervised_agent(subscribe: true, slow: @timeout * 3)

      :ok = Agent.prompt(pid, "hello")

      Process.sleep(@timeout * 2)
      assert Process.alive?(pid)
      assert Agent.get_state(pid, :status) == :running
    end

    test "timer re-arms after the turn completes and test process unsubscribes" do
      {pid, _id} = start_supervised_agent(subscribe: true)

      :ok = Agent.prompt(pid, "hello")
      assert_receive {:agent, ^pid, :stop, _}, 1000

      :ok = Agent.unsubscribe(pid)

      assert {:ok, :normal} = wait_until_dead(pid, @timeout * 4)
    end
  end

  describe "persistence flush on timer fire" do
    @moduletag :tmp_dir

    test "state is persisted when the timer terminates the agent", ctx do
      {pid, id} =
        start_supervised_agent(
          store: FileSystem,
          base_path: ctx.tmp_dir,
          system: "persistent prompt"
        )

      assert {:ok, :normal} = wait_until_dead(pid, @timeout * 4)

      {:ok, loaded} = FileSystem.load(id, base_path: ctx.tmp_dir)
      assert loaded.system == "persistent prompt"
    end
  end

  describe "plain start_link never auto-terminates" do
    test "idle_timeout in opts is ignored without :supervised" do
      stub_name = :"idle_direct_#{System.unique_integer([:positive])}"
      stub_fixture(stub_name, "test/support/fixtures/sse/anthropic_text.sse")

      {:ok, pid} =
        Agent.start_link(
          model: model(),
          opts: [api_key: "test-key", plug: {Req.Test, stub_name}],
          idle_timeout: @timeout
        )

      Process.sleep(@timeout * 4)
      assert Process.alive?(pid)
    end
  end
end
