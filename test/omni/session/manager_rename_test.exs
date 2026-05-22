defmodule Omni.Session.ManagerRenameTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Session.Manager
  alias Omni.Session.Store

  @moduletag :tmp_dir

  defmodule UseMacroManager do
    use Omni.Session.Manager, otp_app: :omni_agent
  end

  setup ctx do
    name = unique_name()
    store = tmp_store(ctx)

    start_supervised!({Manager, name: name, store: store})

    {:ok, manager: name, store: store}
  end

  defp unique_name do
    String.to_atom("Elixir.Omni.Session.ManagerRenameTest.M#{System.unique_integer([:positive])}")
  end

  # ── Running session ──────────────────────────────────────────────

  describe "rename/3 with running session" do
    test "updates title and emits manager :title event", ctx do
      {:ok, _entries} = Manager.subscribe(ctx.manager)

      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, pid} =
        Manager.create(ctx.manager,
          agent: [model: model(), opts: [api_key: "k", plug: {Req.Test, stub_name}]]
        )

      assert_receive {:manager, _, :opened, %{id: id, pid: ^pid}}

      assert :ok = Manager.rename(ctx.manager, id, "New Title")

      assert_receive {:manager, _, :title, %{id: ^id, title: "New Title"}}
      assert Session.get_title(pid) == "New Title"
    end

    test "rename to nil clears the title on a running session", ctx do
      {:ok, _entries} = Manager.subscribe(ctx.manager)

      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      {:ok, pid} =
        Manager.create(ctx.manager,
          title: "Initial",
          agent: [model: model(), opts: [api_key: "k", plug: {Req.Test, stub_name}]]
        )

      assert_receive {:manager, _, :opened, %{id: id}}

      assert :ok = Manager.rename(ctx.manager, id, nil)

      assert_receive {:manager, _, :title, %{id: ^id, title: nil}}
      assert Session.get_title(pid) == nil
    end
  end

  # ── Store-only (not running) ─────────────────────────────────────

  describe "rename/3 with store-only session" do
    test "persists title and emits manager :title event", ctx do
      {:ok, _entries} = Manager.subscribe(ctx.manager)

      :ok = Store.save_state(ctx.store, "parked", %{title: "Old"})

      assert :ok = Manager.rename(ctx.manager, "parked", "Renamed")

      assert_receive {:manager, _, :title, %{id: "parked", title: "Renamed"}}

      {:ok, _tree, state_map} = Store.load(ctx.store, "parked")
      assert state_map[:title] == "Renamed"
    end

    test "rename to nil clears the title in store", ctx do
      :ok = Store.save_state(ctx.store, "titled", %{title: "Has Title"})

      assert :ok = Manager.rename(ctx.manager, "titled", nil)

      {:ok, _tree, state_map} = Store.load(ctx.store, "titled")
      assert state_map[:title] == nil
    end
  end

  # ── Not found ────────────────────────────────────────────────────

  describe "rename/3 when session not found" do
    test "returns {:error, :not_found}", ctx do
      assert {:error, :not_found} = Manager.rename(ctx.manager, "nonexistent", "Title")
    end
  end

  # ── Store error ──────────────────────────────────────────────────

  describe "rename/3 with store error" do
    test "propagates store error on save_state failure", ctx do
      :ok = Store.save_state(ctx.store, "will-fail", %{title: "Before"})

      failing_store =
        {Store.Failing, fail_save_state: :disk_full, delegate: ctx.store}

      name = unique_name()
      start_supervised!({Manager, name: name, store: failing_store})

      assert {:error, :disk_full} = Manager.rename(name, "will-fail", "Fails")
    end
  end

  # ── use macro ────────────────────────────────────────────────────

  describe "use macro" do
    test "exports rename/2" do
      exported =
        UseMacroManager.__info__(:functions)
        |> MapSet.new()

      assert MapSet.member?(exported, {:rename, 2})
    end
  end
end
