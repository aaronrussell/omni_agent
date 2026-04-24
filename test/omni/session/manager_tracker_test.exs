defmodule Omni.Session.ManagerTrackerTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Session.Manager

  @moduletag :tmp_dir

  defmodule UseMacroTrackerManager do
    use Omni.Session.Manager
  end

  setup ctx do
    name = unique_name()
    store = tmp_store(ctx)

    start_supervised!({Manager, name: name, store: store})

    {:ok, manager: name, store: store}
  end

  defp unique_name do
    String.to_atom(
      "Elixir.Omni.Session.ManagerTrackerTest.TM#{System.unique_integer([:positive])}"
    )
  end

  defp minimal_agent, do: [model: model()]

  defp stubbed_agent(stub_name) do
    [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]]
  end

  # Waits until fun.() returns a non-nil value or the deadline passes.
  defp wait_until(fun, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          nil
        else
          Process.sleep(10)
          do_wait(fun, deadline)
        end

      value ->
        value
    end
  end

  defp tracker_pid(manager), do: Process.whereis(Module.concat(manager, Tracker))

  # Drains the caller mailbox of any {:manager, _, _, _} messages.
  defp flush_manager_events do
    receive do
      {:manager, _, _, _} -> flush_manager_events()
    after
      0 -> :ok
    end
  end

  # ── use macro ──────────────────────────────────────────────────────

  describe "use macro" do
    test "generates list_open/0, subscribe/0, unsubscribe/0" do
      exported =
        UseMacroTrackerManager.__info__(:functions)
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 {:list_open, 0},
                 {:subscribe, 0},
                 {:unsubscribe, 0}
               ]),
               exported
             )
    end
  end

  # ── list_open/1 ─────────────────────────────────────────────────

  describe "list_open/1" do
    test "reports a freshly created session", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "a", agent: minimal_agent(), subscribe: false)

      assert [entry] = Manager.list_open(m)
      assert entry.id == "a"
      assert entry.pid == pid
      assert entry.status == :idle
      assert entry.title == nil
    end

    test "includes the title when provided at create", %{manager: m} do
      {:ok, _pid} =
        Manager.create(m, id: "t", title: "hello", agent: minimal_agent(), subscribe: false)

      assert [%{id: "t", title: "hello"}] = Manager.list_open(m)
    end

    test "returns an empty list when no sessions are running", %{manager: m} do
      assert Manager.list_open(m) == []
    end

    test "reflects multiple sessions", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "x", agent: minimal_agent(), subscribe: false)
      {:ok, _} = Manager.create(m, id: "y", agent: minimal_agent(), subscribe: false)

      ids = Manager.list_open(m) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["x", "y"]
    end

    test "drops an entry after close", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "gone", agent: minimal_agent(), subscribe: false)
      :ok = Manager.close(m, "gone")

      assert wait_until(fn ->
               if Manager.list_open(m) == [], do: :done, else: nil
             end) == :done
    end
  end

  # ── subscribe/unsubscribe basics ───────────────────────────────────

  describe "subscribe/1" do
    test "returns an atomic snapshot of currently running sessions", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "pre", agent: minimal_agent(), subscribe: false)

      assert {:ok, [entry]} = Manager.subscribe(m)
      assert entry.id == "pre"
    end

    test "is idempotent per pid", %{manager: m} do
      {:ok, []} = Manager.subscribe(m)
      {:ok, []} = Manager.subscribe(m)

      tracker_state = :sys.get_state(tracker_pid(m))
      assert MapSet.size(tracker_state.subscribers) == 1
      assert MapSet.member?(tracker_state.subscribers, self())
    end

    test "unsubscribe stops event delivery", %{manager: m} do
      {:ok, []} = Manager.subscribe(m)
      :ok = Manager.unsubscribe(m)

      {:ok, _pid} = Manager.create(m, id: "after", agent: minimal_agent(), subscribe: false)

      refute_receive {:manager, ^m, :session_added, _}, 100
    end
  end

  # ── :session_added ─────────────────────────────────────────────────

  describe ":session_added" do
    test "fires on create", %{manager: m} do
      {:ok, []} = Manager.subscribe(m)
      {:ok, pid} = Manager.create(m, id: "added", agent: minimal_agent(), subscribe: false)

      assert_receive {:manager, ^m, :session_added, entry}, 500
      assert entry.id == "added"
      assert entry.pid == pid
      assert entry.status == :idle
    end

    test "fires on open :started after a close/reopen", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "reborn", agent: minimal_agent(), subscribe: false)
      # set_title triggers save_state so the session is persisted.
      :ok = Omni.Session.set_title(pid, "persist")
      :ok = Manager.close(m, "reborn")

      assert wait_until(fn ->
               if Manager.whereis(m, "reborn") == nil, do: :done, else: nil
             end) == :done

      {:ok, _} = Manager.subscribe(m)

      {:ok, _pid, :started} = Manager.open(m, "reborn", agent: minimal_agent(), subscribe: false)
      assert_receive {:manager, ^m, :session_added, %{id: "reborn"}}, 500
    end

    test "does NOT fire on open :existing", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "live", agent: minimal_agent(), subscribe: false)

      {:ok, _} = Manager.subscribe(m)

      {:ok, _pid, :existing} = Manager.open(m, "live", subscribe: false)
      refute_receive {:manager, ^m, :session_added, _}, 100
    end
  end

  # ── :session_status ────────────────────────────────────────────────

  describe ":session_status" do
    test "fires on turn start and completion", %{manager: m, tmp_dir: _} do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, []} = Manager.subscribe(m)

      {:ok, pid} =
        Manager.create(m, id: "s1", agent: stubbed_agent(stub_name), subscribe: false)

      Omni.Session.prompt(pid, "hi")

      assert_receive {:manager, ^m, :session_status, %{id: "s1", status: :busy}}, 500
      assert_receive {:manager, ^m, :session_status, %{id: "s1", status: :idle}}, 2000
    end

    test "list_open reflects the latest status", %{manager: m} do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, pid} = Manager.create(m, id: "s2", agent: stubbed_agent(stub_name), subscribe: false)

      {:ok, _} = Manager.subscribe(m)
      Omni.Session.prompt(pid, "hi")

      assert_receive {:manager, ^m, :session_status, %{status: :idle}}, 2000

      assert [%{id: "s2", status: :idle}] = Manager.list_open(m)
    end
  end

  # ── :session_title ─────────────────────────────────────────────────

  describe ":session_title" do
    test "fires on set_title and updates the tracker entry", %{manager: m} do
      {:ok, pid} =
        Manager.create(m, id: "t1", title: "old", agent: minimal_agent(), subscribe: false)

      {:ok, [%{id: "t1", title: "old"}]} = Manager.subscribe(m)

      :ok = Omni.Session.set_title(pid, "new")

      assert_receive {:manager, ^m, :session_title, %{id: "t1", title: "new"}}, 500
      assert [%{title: "new"}] = Manager.list_open(m)
    end
  end

  # ── :session_removed ───────────────────────────────────────────────

  describe ":session_removed" do
    test "fires on close", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "c1", agent: minimal_agent(), subscribe: false)

      {:ok, _} = Manager.subscribe(m)
      :ok = Manager.close(m, "c1")

      assert_receive {:manager, ^m, :session_removed, %{id: "c1"}}, 500
      assert Manager.list_open(m) == []
    end

    test "fires on delete", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "d1", agent: minimal_agent(), subscribe: false)

      {:ok, _} = Manager.subscribe(m)
      :ok = Manager.delete(m, "d1")

      assert_receive {:manager, ^m, :session_removed, %{id: "d1"}}, 500
    end

    @tag :capture_log
    test "fires on crash", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "crash", agent: minimal_agent(), subscribe: false)

      {:ok, _} = Manager.subscribe(m)
      Process.exit(pid, :kill)

      assert_receive {:manager, ^m, :session_removed, %{id: "crash"}}, 500
      assert Manager.list_open(m) == []
    end

    test "fires after idle-shutdown", %{manager: m} do
      {:ok, pid} =
        Manager.create(m, id: "idle", agent: minimal_agent(), idle_shutdown_after: 50)

      {:ok, _} = Manager.subscribe(m)

      # Caller was auto-subscribed as controller; dropping it to 0 with
      # agent idle arms the shutdown timer.
      :ok = Omni.Session.unsubscribe(pid)

      assert_receive {:manager, ^m, :session_removed, %{id: "idle"}}, 500
    end
  end

  # ── Subscriber cleanup ─────────────────────────────────────────────

  describe "subscriber cleanup" do
    test "removes subscribers from state on death", %{manager: m} do
      parent = self()

      task =
        Task.async(fn ->
          Manager.subscribe(m)
          send(parent, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready, 500

      tracker = tracker_pid(m)
      pre = :sys.get_state(tracker).subscribers
      assert MapSet.member?(pre, task.pid)

      send(task.pid, :stop)
      Task.await(task)

      assert wait_until(fn ->
               if MapSet.member?(:sys.get_state(tracker).subscribers, task.pid) do
                 nil
               else
                 :done
               end
             end) == :done
    end
  end

  # ── Tracker crash and rebuild ──────────────────────────────────────

  describe "Tracker crash recovery" do
    test "rebuilds list_open after restart", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "a", agent: minimal_agent(), subscribe: false)
      {:ok, _} = Manager.create(m, id: "b", agent: minimal_agent(), subscribe: false)

      tracker = tracker_pid(m)
      assert tracker != nil

      ref = Process.monitor(tracker)
      Process.exit(tracker, :kill)

      assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}, 500

      # Wait for supervisor restart under a new pid.
      new_tracker =
        wait_until(fn ->
          case tracker_pid(m) do
            nil -> nil
            pid when pid == tracker -> nil
            pid -> pid
          end
        end)

      assert is_pid(new_tracker)

      ids =
        wait_until(fn ->
          case Manager.list_open(m) |> Enum.map(& &1.id) |> Enum.sort() do
            ["a", "b"] = ids -> ids
            _ -> nil
          end
        end)

      assert ids == ["a", "b"]
    end

    test "Manager-level subscribers are dropped on Tracker crash", %{manager: m} do
      {:ok, _} = Manager.subscribe(m)

      tracker = tracker_pid(m)
      ref = Process.monitor(tracker)
      Process.exit(tracker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}, 500

      new_tracker =
        wait_until(fn ->
          case tracker_pid(m) do
            nil -> nil
            pid when pid == tracker -> nil
            pid -> pid
          end
        end)

      assert is_pid(new_tracker)

      # Caller is no longer a subscriber — a new session emits nothing to us.
      flush_manager_events()
      {:ok, _} = Manager.create(m, id: "post", agent: minimal_agent(), subscribe: false)
      refute_receive {:manager, ^m, :session_added, _}, 100

      # Re-subscribing works and sees the existing session.
      assert {:ok, entries} = Manager.subscribe(m)
      assert Enum.any?(entries, &(&1.id == "post"))
    end
  end

  # ── Multi-Manager independence ─────────────────────────────────────

  describe "multi-Manager independence" do
    test "events carry the correct Manager module", ctx do
      name_a = unique_name()
      name_b = unique_name()

      start_supervised!({Manager, name: name_a, store: tmp_store(ctx)}, id: name_a)
      start_supervised!({Manager, name: name_b, store: tmp_store(ctx)}, id: name_b)

      {:ok, _} = Manager.subscribe(name_a)
      {:ok, _} = Manager.subscribe(name_b)

      {:ok, _} = Manager.create(name_a, id: "in_a", agent: minimal_agent(), subscribe: false)
      {:ok, _} = Manager.create(name_b, id: "in_b", agent: minimal_agent(), subscribe: false)

      assert_receive {:manager, ^name_a, :session_added, %{id: "in_a"}}, 500
      assert_receive {:manager, ^name_b, :session_added, %{id: "in_b"}}, 500

      # No cross-talk.
      refute_receive {:manager, ^name_a, :session_added, %{id: "in_b"}}, 100
      refute_receive {:manager, ^name_b, :session_added, %{id: "in_a"}}, 100
    end
  end
end
