defmodule Omni.Agent.PersistenceTest do
  use Omni.Agent.AgentCase, async: true

  alias Omni.Agent
  alias Omni.Agent.Store.{FileSystem, Stub}
  alias Omni.Agent.Tree

  describe "save_tree on every push" do
    test "user push fires save_tree with the new node's id" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a")
      assert_receive {:save_state, "a", _state_data, _}

      :ok = Agent.prompt(pid, "hello")

      assert_receive {:save_tree, "a", %Tree{} = tree, opts}
      assert Keyword.get(opts, :new_node_ids) == [1]
      assert Tree.size(tree) == 1

      # assistant response step completes
      assert_receive {:save_tree, "a", %Tree{} = tree2, opts2}
      assert Keyword.get(opts2, :new_node_ids) == [2]
      assert Tree.size(tree2) == 2
    end

    test "adapter opts thread through to save_tree" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a", custom_adapter_opt: :foo)
      assert_receive {:save_state, "a", _state_data, _}

      :ok = Agent.prompt(pid, "hello")

      assert_receive {:save_tree, "a", _, opts}
      assert Keyword.get(opts, :custom_adapter_opt) == :foo
    end
  end

  describe "save_state on set_state" do
    test "set_state/2 triggers save_state with serialisable fields" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a")
      assert_receive {:save_state, "a", _initial, _}

      :ok = Agent.set_state(pid, system: "updated prompt")

      assert_receive {:save_state, "a", state_data, _}
      assert state_data.system == "updated prompt"
      assert is_map(state_data.meta)
      assert Map.has_key?(state_data, :model)
    end

    test "set_state/3 (field + value) triggers save_state" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a")
      assert_receive {:save_state, "a", _initial, _}

      :ok = Agent.set_state(pid, :meta, %{title: "New"})

      assert_receive {:save_state, "a", state_data, _}
      assert state_data.meta == %{title: "New"}
    end

    test "set_state/3 (field + function) triggers save_state with updated value" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a", meta: %{count: 0})
      assert_receive {:save_state, "a", _initial, _}

      :ok = Agent.set_state(pid, :meta, &Map.update!(&1, :count, fn n -> n + 1 end))

      assert_receive {:save_state, "a", state_data, _}
      assert state_data.meta == %{count: 1}
    end

    test "failed set_state does not trigger save_state" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a")
      assert_receive {:save_state, "a", _initial, _}

      {:error, {:invalid_field, :not_a_field}} = Agent.set_state(pid, :not_a_field, :x)

      refute_receive {:save_state, _, _, _}, 50
    end
  end

  describe "error surfacing via :store event" do
    test "save_tree error broadcasts :store event and agent keeps running" do
      {:ok, pid} =
        start_agent(
          store: Stub,
          probe: self(),
          new: "a",
          errors: %{save_tree: :disk_full}
        )

      :ok = Agent.prompt(pid, "hello")

      assert_receive {:agent, ^pid, :store, {:error, {:save_tree, :disk_full}}}

      # Agent keeps running — turn still completes and a subsequent prompt
      # still works.
      assert_receive {:agent, ^pid, :stop, _response}
      assert Agent.get_state(pid, :status) == :idle
    end

    test "save_state error broadcasts :store event and set_state still returns :ok" do
      {:ok, pid} =
        start_agent(
          store: Stub,
          probe: self(),
          new: "a",
          errors: %{save_state: :read_only}
        )

      # Drain the init save_state call (which also errors, but we don't care here).
      _ = Process.info(pid, :message_queue_len)

      assert :ok = Agent.set_state(pid, system: "new prompt")

      assert_receive {:agent, ^pid, :store, {:error, {:save_state, :read_only}}}
      assert Agent.get_state(pid, :system) == "new prompt"
    end

    test "subsequent ops still work after a save error" do
      {:ok, pid} =
        start_agent(
          store: Stub,
          probe: self(),
          new: "a",
          errors: %{save_tree: :io_error}
        )

      :ok = Agent.prompt(pid, "hello")
      assert_receive {:agent, ^pid, :stop, _}
      assert_receive {:agent, ^pid, :store, {:error, {:save_tree, :io_error}}}

      assert Agent.get_state(pid, :status) == :idle
      # Tree lives in memory even though persistence failed
      assert Tree.size(Agent.get_state(pid, :tree)) == 2
    end
  end

  describe "terminate flush" do
    test "GenServer.stop fires a final save_state" do
      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "a")
      assert_receive {:save_state, "a", _initial, _}

      GenServer.stop(pid, :normal)

      # The flush save_state call fires during terminate. It might be
      # followed by additional stub reports during shutdown; we only
      # care that at least one more save_state reached the stub.
      assert_receive {:save_state, "a", _final, _}, 500
    end
  end

  describe "end-to-end via FileSystem" do
    @moduletag :tmp_dir

    test "create → prompt → stop → FileSystem.load restores the tree", ctx do
      {:ok, pid} =
        start_agent(
          store: FileSystem,
          base_path: ctx.tmp_dir,
          new: "roundtrip",
          system: "you are helpful"
        )

      :ok = Agent.prompt(pid, "hello")
      assert_receive {:agent, ^pid, :stop, _}, 1000

      live_tree = Agent.get_state(pid, :tree)
      GenServer.stop(pid, :normal)

      {:ok, persisted} = FileSystem.load("roundtrip", base_path: ctx.tmp_dir)
      assert persisted.tree == live_tree
      assert persisted.system == "you are helpful"
      assert Tree.size(persisted.tree) == 2
    end
  end

  describe "start_link without Manager" do
    test "persistence works when Manager isn't started" do
      refute Process.whereis(Omni.Agent.Manager)

      {:ok, pid} = start_agent(store: Stub, probe: self(), new: "direct")
      assert_receive {:save_state, "direct", _, _}

      :ok = Agent.prompt(pid, "hello")
      assert_receive {:save_tree, "direct", _, _}
    end
  end
end
