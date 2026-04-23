defmodule Omni.Session.ManagerTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Session.Manager
  alias Omni.Session.Store.FileSystem

  @moduletag :tmp_dir

  # Module used to exercise the `use Omni.Session.Manager` path. Only
  # lives here — the other tests bypass the macro and call the
  # `Manager.*` functions with an explicit name atom.
  defmodule UseMacroManager do
    use Omni.Session.Manager
  end

  # Each test gets its own Manager instance, registered under a unique
  # atom so the Registry/DynamicSupervisor names don't collide across
  # async tests.
  setup ctx do
    name = unique_name()
    store = tmp_store(ctx)

    start_supervised!({Manager, name: name, store: store})

    {:ok, manager: name, store: store}
  end

  defp unique_name do
    String.to_atom("Elixir.Omni.Session.ManagerTest.TM#{System.unique_integer([:positive])}")
  end

  defp minimal_agent, do: [model: model()]

  defp session_state(pid), do: :sys.get_state(pid)

  # ── use macro ──────────────────────────────────────────────────────

  describe "use macro" do
    test "generates the expected delegations", _ctx do
      exported =
        UseMacroManager.__info__(:functions)
        |> Enum.map(fn {name, arity} -> {name, arity} end)
        |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 {:child_spec, 1},
                 {:start_link, 0},
                 {:start_link, 1},
                 {:create, 0},
                 {:create, 1},
                 {:open, 1},
                 {:open, 2},
                 {:close, 1},
                 {:delete, 1},
                 {:whereis, 1},
                 {:list, 0},
                 {:list, 1}
               ]),
               exported
             )
    end
  end

  # ── create/2 ───────────────────────────────────────────────────────

  describe "create/2" do
    test "auto-generates an id when :id is omitted", %{manager: m} do
      {:ok, pid} = Manager.create(m, agent: minimal_agent(), subscribe: false)
      id = session_state(pid).id

      assert byte_size(id) == 22
      assert Manager.whereis(m, id) == pid
    end

    test "uses :id when provided", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "mine", agent: minimal_agent(), subscribe: false)

      assert session_state(pid).id == "mine"
      assert Manager.whereis(m, "mine") == pid
    end

    test "returns :already_exists when :id is running", %{manager: m} do
      {:ok, _} = Manager.create(m, id: "x", agent: minimal_agent(), subscribe: false)

      assert {:error, :already_exists} =
               Manager.create(m, id: "x", agent: minimal_agent(), subscribe: false)
    end

    test "returns :already_exists when :id is in the store but not running",
         %{manager: m, store: store} do
      :ok = Omni.Session.Store.save_state(store, "parked", %{title: "prior"})

      assert {:error, :already_exists} =
               Manager.create(m, id: "parked", agent: minimal_agent(), subscribe: false)
    end

    test "rejects Manager-owned opts", %{manager: m} do
      assert {:error, {:invalid_opt, :store}} =
               Manager.create(m, store: {FileSystem, base_path: "/tmp"}, agent: minimal_agent())

      assert {:error, {:invalid_opt, :name}} = Manager.create(m, name: :nope)
      assert {:error, {:invalid_opt, :new}} = Manager.create(m, new: "a")
      assert {:error, {:invalid_opt, :load}} = Manager.create(m, load: "a")
    end

    test "rejects a non-binary :id", %{manager: m} do
      assert {:error, {:invalid_opt, :id}} =
               Manager.create(m, id: 123, agent: minimal_agent())
    end

    test "forwards Session errors", %{manager: m} do
      # :missing_agent from Session.validate_opts
      assert {:error, :missing_agent} = Manager.create(m)
    end

    test "subscribes caller as controller by default", %{manager: m} do
      {:ok, pid} = Manager.create(m, agent: minimal_agent())

      controllers = session_state(pid).controllers
      assert MapSet.member?(controllers, self())
    end

    test "subscribe: false keeps caller out of controllers", %{manager: m} do
      {:ok, pid} = Manager.create(m, agent: minimal_agent(), subscribe: false)

      controllers = session_state(pid).controllers
      refute MapSet.member?(controllers, self())
    end

    test "Manager default idle_shutdown_after flows to session", %{manager: m} do
      {:ok, pid} = Manager.create(m, agent: minimal_agent(), subscribe: false)

      assert session_state(pid).idle_shutdown_after == 300_000
    end

    test "per-call idle_shutdown_after overrides Manager default", %{manager: m} do
      {:ok, pid} =
        Manager.create(m, agent: minimal_agent(), subscribe: false, idle_shutdown_after: 60_000)

      assert session_state(pid).idle_shutdown_after == 60_000
    end

    test "per-call idle_shutdown_after: nil disables shutdown for that session",
         %{manager: m} do
      {:ok, pid} =
        Manager.create(m, agent: minimal_agent(), subscribe: false, idle_shutdown_after: nil)

      assert session_state(pid).idle_shutdown_after == nil
    end
  end

  # ── Manager config overrides ───────────────────────────────────────

  describe "Manager-config idle_shutdown_after" do
    test "custom Manager default flows to every session", ctx do
      # Override the default setup by starting a second Manager with a
      # non-default idle_shutdown_after.
      name = unique_name()

      start_supervised!(
        {Manager, name: name, store: tmp_store(ctx), idle_shutdown_after: 60_000},
        id: name
      )

      {:ok, pid} = Manager.create(name, agent: minimal_agent(), subscribe: false)
      assert session_state(pid).idle_shutdown_after == 60_000
    end

    test "Manager default of nil disables shutdown for every session", ctx do
      name = unique_name()

      start_supervised!(
        {Manager, name: name, store: tmp_store(ctx), idle_shutdown_after: nil},
        id: name
      )

      {:ok, pid} = Manager.create(name, agent: minimal_agent(), subscribe: false)
      assert session_state(pid).idle_shutdown_after == nil
    end
  end

  # ── open/3 ─────────────────────────────────────────────────────────

  describe "open/3" do
    test ":not_found when id is absent from the store", %{manager: m} do
      assert {:error, :not_found} = Manager.open(m, "nope", agent: minimal_agent())
    end

    test "started branch: loads from store", %{manager: m, store: store} do
      # Pre-persist a session via a throwaway process.
      {:ok, tmp} = Manager.create(m, id: "abc", agent: minimal_agent(), subscribe: false)
      :ok = Omni.Session.set_title(tmp, "original")
      :ok = Manager.close(m, "abc")

      # Independent check: the session is persisted.
      assert Omni.Session.Store.exists?(store, "abc")

      assert {:ok, :started, pid} = Manager.open(m, "abc", agent: minimal_agent())
      assert session_state(pid).id == "abc"
      assert Manager.whereis(m, "abc") == pid
    end

    test "existing branch: returns the running pid with opts dropped", %{manager: m} do
      {:ok, pid1} =
        Manager.create(m, id: "live", agent: minimal_agent(), title: "original", subscribe: false)

      assert {:ok, :existing, pid2} =
               Manager.open(m, "live", agent: minimal_agent(), title: "would-be-new")

      assert pid1 == pid2
      assert session_state(pid1).title == "original"
    end

    test "subscribes caller as controller on :started", %{manager: m} do
      {:ok, tmp} = Manager.create(m, id: "s", agent: minimal_agent(), subscribe: false)
      :ok = Omni.Session.set_title(tmp, "persist")
      :ok = Manager.close(m, "s")

      {:ok, :started, pid} = Manager.open(m, "s", agent: minimal_agent())

      assert MapSet.member?(session_state(pid).controllers, self())
    end

    test "subscribes caller as controller on :existing", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "e", agent: minimal_agent(), subscribe: false)

      assert {:ok, :existing, ^pid} = Manager.open(m, "e")
      assert MapSet.member?(session_state(pid).controllers, self())
    end

    test "subscribe: false honored on :started", %{manager: m} do
      {:ok, tmp} = Manager.create(m, id: "n", agent: minimal_agent(), subscribe: false)
      :ok = Omni.Session.set_title(tmp, "persist")
      :ok = Manager.close(m, "n")

      {:ok, :started, pid} = Manager.open(m, "n", agent: minimal_agent(), subscribe: false)

      refute MapSet.member?(session_state(pid).controllers, self())
    end

    test "subscribe: false honored on :existing", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "n2", agent: minimal_agent(), subscribe: false)

      assert {:ok, :existing, ^pid} = Manager.open(m, "n2", subscribe: false)
      refute MapSet.member?(session_state(pid).controllers, self())
    end

    test "rejects Manager-owned opts", %{manager: m} do
      assert {:error, {:invalid_opt, :store}} =
               Manager.open(m, "x", store: {FileSystem, base_path: "/tmp"})

      assert {:error, {:invalid_opt, :new}} = Manager.open(m, "x", new: "y")
      assert {:error, {:invalid_opt, :load}} = Manager.open(m, "x", load: "y")
      assert {:error, {:invalid_opt, :name}} = Manager.open(m, "x", name: :nope)
    end
  end

  # ── close/2 ────────────────────────────────────────────────────────

  describe "close/2" do
    test "stops a running session and clears the registry", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "c", agent: minimal_agent(), subscribe: false)
      ref = Process.monitor(pid)

      assert :ok = Manager.close(m, "c")
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert eventually(fn -> Manager.whereis(m, "c") == nil end)
    end

    test "is idempotent when the id has never run", %{manager: m} do
      assert :ok = Manager.close(m, "never")
    end

    test "is idempotent when the session already died", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "x", agent: minimal_agent(), subscribe: false)
      ref = Process.monitor(pid)
      :ok = Omni.Session.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert :ok = Manager.close(m, "x")
    end
  end

  # ── delete/2 ───────────────────────────────────────────────────────

  describe "delete/2" do
    test "stops and then deletes from store", %{manager: m, store: store} do
      {:ok, pid} = Manager.create(m, id: "d", agent: minimal_agent(), subscribe: false)
      :ok = Omni.Session.set_title(pid, "persist me")

      assert :ok = Manager.delete(m, "d")
      assert eventually(fn -> Manager.whereis(m, "d") == nil end)
      refute Omni.Session.Store.exists?(store, "d")
    end

    test "deletes a persisted-but-not-running session", %{manager: m, store: store} do
      :ok = Omni.Session.Store.save_state(store, "parked", %{title: "prior"})
      assert Omni.Session.Store.exists?(store, "parked")

      assert :ok = Manager.delete(m, "parked")
      refute Omni.Session.Store.exists?(store, "parked")
    end

    test "propagates Store.delete errors", ctx do
      name = unique_name()
      inner = tmp_store(ctx)
      store = {Omni.Session.Store.Failing, delegate: inner, fail_delete: :boom}

      start_supervised!({Manager, name: name, store: store}, id: name)

      assert {:error, :boom} = Manager.delete(name, "anything")
    end
  end

  # ── whereis/2 ──────────────────────────────────────────────────────

  describe "whereis/2" do
    test "returns pid for a registered id", %{manager: m} do
      {:ok, pid} = Manager.create(m, id: "w", agent: minimal_agent(), subscribe: false)
      assert Manager.whereis(m, "w") == pid
    end

    test "returns nil for unknown id", %{manager: m} do
      assert Manager.whereis(m, "nope") == nil
    end
  end

  # ── list/2 ─────────────────────────────────────────────────────────

  describe "list/2" do
    test "pass-through with empty store", %{manager: m} do
      assert {:ok, []} = Manager.list(m)
    end

    test "returns persisted sessions", %{manager: m} do
      {:ok, p1} = Manager.create(m, id: "a", agent: minimal_agent(), subscribe: false)
      {:ok, p2} = Manager.create(m, id: "b", agent: minimal_agent(), subscribe: false)
      :ok = Omni.Session.set_title(p1, "A")
      :ok = Omni.Session.set_title(p2, "B")

      {:ok, sessions} = Manager.list(m)
      ids = sessions |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "honours :limit and :offset", %{manager: m} do
      for id <- ~w(a b c) do
        {:ok, pid} = Manager.create(m, id: id, agent: minimal_agent(), subscribe: false)
        :ok = Omni.Session.set_title(pid, id)
      end

      {:ok, page1} = Manager.list(m, limit: 2)
      assert length(page1) == 2

      {:ok, page2} = Manager.list(m, limit: 2, offset: 2)
      assert length(page2) == 1
    end
  end

  # ── isolation across Managers ──────────────────────────────────────

  describe "multiple Managers" do
    test "separate Registry and Store per Manager", ctx do
      m1 = unique_name()
      m2 = unique_name()

      store1 = {FileSystem, base_path: Path.join(ctx.tmp_dir, "m1")}
      store2 = {FileSystem, base_path: Path.join(ctx.tmp_dir, "m2")}

      start_supervised!({Manager, name: m1, store: store1}, id: m1)
      start_supervised!({Manager, name: m2, store: store2}, id: m2)

      {:ok, p1} = Manager.create(m1, id: "shared", agent: minimal_agent(), subscribe: false)
      {:ok, p2} = Manager.create(m2, id: "shared", agent: minimal_agent(), subscribe: false)

      assert p1 != p2
      assert Manager.whereis(m1, "shared") == p1
      assert Manager.whereis(m2, "shared") == p2

      ref = Process.monitor(p1)
      :ok = Manager.close(m1, "shared")
      assert_receive {:DOWN, ^ref, :process, ^p1, _}, 500
      assert eventually(fn -> Manager.whereis(m1, "shared") == nil end)

      assert Manager.whereis(m2, "shared") == p2
    end
  end

  # ── Manager start-up validation ────────────────────────────────────

  describe "start_link validation" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "raises without :store" do
      assert {:error, {%ArgumentError{message: msg}, _}} =
               Manager.start_link(name: unique_name())

      assert msg =~ ":store"
    end

    test "raises on non-tuple :store" do
      assert {:error, {%ArgumentError{message: msg}, _}} =
               Manager.start_link(name: unique_name(), store: :not_a_tuple)

      assert msg =~ ":store must be"
    end

    test "raises on invalid idle_shutdown_after", ctx do
      assert {:error, {%ArgumentError{message: msg}, _}} =
               Manager.start_link(
                 name: unique_name(),
                 store: tmp_store(ctx),
                 idle_shutdown_after: -1
               )

      assert msg =~ ":idle_shutdown_after"
    end

    test "raises without :name", ctx do
      assert_raise ArgumentError, ~r/:name/, fn ->
        Manager.start_link(store: tmp_store(ctx))
      end
    end
  end
end
