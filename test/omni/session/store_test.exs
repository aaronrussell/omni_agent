defmodule Omni.Session.StoreTest do
  use ExUnit.Case, async: true

  alias Omni.Message
  alias Omni.Session.{Store, Tree}

  # Minimal adapter that echoes each call back to the test process,
  # used to verify that Store dispatch unpacks `{module, config}`
  # correctly and forwards arguments in order.
  defmodule EchoAdapter do
    @behaviour Omni.Session.Store

    @impl true
    def save_tree(config, id, tree, opts) do
      send(config[:test_pid], {:save_tree, config, id, tree, opts})
      :ok
    end

    @impl true
    def save_state(config, id, state_map, opts) do
      send(config[:test_pid], {:save_state, config, id, state_map, opts})
      :ok
    end

    @impl true
    def load(config, id, opts) do
      send(config[:test_pid], {:load, config, id, opts})
      {:ok, %Tree{}, %{}}
    end

    @impl true
    def list(config, opts) do
      send(config[:test_pid], {:list, config, opts})
      {:ok, []}
    end

    @impl true
    def delete(config, id, opts) do
      send(config[:test_pid], {:delete, config, id, opts})
      :ok
    end

    @impl true
    def exists?(config, id) do
      send(config[:test_pid], {:exists?, config, id})
      false
    end
  end

  setup do
    %{store: {EchoAdapter, test_pid: self()}}
  end

  describe "save_tree/4" do
    test "forwards to adapter with config unpacked", %{store: store} do
      tree = Tree.push(%Tree{}, Message.new("hi"))

      assert :ok = Store.save_tree(store, "abc", tree, new_node_ids: [1])
      assert_received {:save_tree, config, "abc", ^tree, [new_node_ids: [1]]}
      assert config[:test_pid] == self()
    end

    test "defaults opts to []", %{store: store} do
      assert :ok = Store.save_tree(store, "abc", %Tree{})
      assert_received {:save_tree, _cfg, "abc", %Tree{}, []}
    end
  end

  describe "save_state/4" do
    test "forwards to adapter with config unpacked", %{store: store} do
      state = %{title: "hello"}

      assert :ok = Store.save_state(store, "abc", state, extra: true)
      assert_received {:save_state, _cfg, "abc", ^state, [extra: true]}
    end

    test "defaults opts to []", %{store: store} do
      assert :ok = Store.save_state(store, "abc", %{})
      assert_received {:save_state, _cfg, "abc", %{}, []}
    end
  end

  describe "load/3" do
    test "forwards to adapter with config unpacked", %{store: store} do
      assert {:ok, %Tree{}, %{}} = Store.load(store, "abc", foo: :bar)
      assert_received {:load, _cfg, "abc", [foo: :bar]}
    end

    test "defaults opts to []", %{store: store} do
      Store.load(store, "abc")
      assert_received {:load, _cfg, "abc", []}
    end
  end

  describe "list/2" do
    test "forwards to adapter with config unpacked", %{store: store} do
      assert {:ok, []} = Store.list(store, limit: 10, offset: 5)
      assert_received {:list, _cfg, [limit: 10, offset: 5]}
    end

    test "defaults opts to []", %{store: store} do
      Store.list(store)
      assert_received {:list, _cfg, []}
    end
  end

  describe "delete/3" do
    test "forwards to adapter with config unpacked", %{store: store} do
      assert :ok = Store.delete(store, "abc", force: true)
      assert_received {:delete, _cfg, "abc", [force: true]}
    end

    test "defaults opts to []", %{store: store} do
      Store.delete(store, "abc")
      assert_received {:delete, _cfg, "abc", []}
    end
  end

  describe "exists?/2" do
    test "forwards to adapter with config unpacked", %{store: store} do
      assert false == Store.exists?(store, "abc")
      assert_received {:exists?, _cfg, "abc"}
    end
  end
end
