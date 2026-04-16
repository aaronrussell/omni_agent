defmodule Omni.Agent.StartOptsTest do
  use ExUnit.Case, async: true

  alias Omni.Agent
  alias Omni.Agent.Store.FileSystem
  alias Omni.Agent.Tree
  alias Omni.Message

  @moduletag :tmp_dir

  defp model, do: {:anthropic, "claude-haiku-4-5"}

  defp base_opts(%{tmp_dir: tmp_dir}) do
    [model: model(), store: FileSystem, base_path: tmp_dir]
  end

  defp start_link_silent(opts) do
    # Swallow the standard GenServer :EXIT spam when an init returns
    # {:stop, reason} — the start_link caller already sees the error.
    Process.flag(:trap_exit, true)
    result = Agent.start_link(opts)
    Process.flag(:trap_exit, false)
    result
  end

  defp assert_init_error(opts, reason) do
    assert {:error, ^reason} = start_link_silent(opts)
  end

  describe "opt-error table" do
    test ":new without :store → :store_required" do
      assert_init_error([model: model(), new: "x"], :store_required)
    end

    test ":load without :store → :store_required" do
      assert_init_error([model: model(), load: "x"], :store_required)
    end

    test "both :new and :load → :conflicting_opts", ctx do
      opts = Keyword.merge(base_opts(ctx), new: "x", load: "y")
      assert_init_error(opts, :conflicting_opts)
    end

    test ":load with :tree → {:invalid_load_opts, [:tree]}", ctx do
      opts = Keyword.merge(base_opts(ctx), load: "x", tree: %Tree{})
      assert_init_error(opts, {:invalid_load_opts, [:tree]})
    end

    test ":load with :meta → {:invalid_load_opts, [:meta]}", ctx do
      opts = Keyword.merge(base_opts(ctx), load: "x", meta: %{})
      assert_init_error(opts, {:invalid_load_opts, [:meta]})
    end

    test ":load with both :tree and :meta → {:invalid_load_opts, [:tree, :meta]}", ctx do
      opts = Keyword.merge(base_opts(ctx), load: "x", tree: %Tree{}, meta: %{})
      assert_init_error(opts, {:invalid_load_opts, [:tree, :meta]})
    end

    test ":id with :store → {:invalid_opts, [:id]}", ctx do
      opts = Keyword.merge(base_opts(ctx), id: "x")
      assert_init_error(opts, {:invalid_opts, [:id]})
    end

    test ":id with :new (no :store) → :store_required (new-without-store wins)" do
      # :new-without-store is evaluated first; exact error doesn't matter as
      # much as surfacing an error at all.
      assert_init_error([model: model(), id: "x", new: "y"], :store_required)
    end

    test ":new with an id that already exists → :already_exists", ctx do
      # Seed existing state for "taken".
      :ok = FileSystem.save_state("taken", sample_state(), base_path: ctx.tmp_dir)

      opts = Keyword.merge(base_opts(ctx), new: "taken")
      assert_init_error(opts, :already_exists)
    end

    test ":load with a missing id → :not_found", ctx do
      opts = Keyword.merge(base_opts(ctx), load: "ghost")
      assert_init_error(opts, :not_found)
    end
  end

  describe "ephemeral mode" do
    test "nothing is persisted", ctx do
      {:ok, _pid} = Agent.start_link(model: model(), id: "ephem")

      assert File.ls(ctx.tmp_dir) == {:ok, []}
    end

    test "state.id is opts[:id] when given" do
      {:ok, pid} = Agent.start_link(model: model(), id: "ephem")
      assert Agent.get_state(pid, :id) == "ephem"
    end

    test "state.id is nil when :id omitted" do
      {:ok, pid} = Agent.start_link(model: model())
      assert Agent.get_state(pid, :id) == nil
    end
  end

  describe "new mode" do
    test "creates a fresh agent and saves initial state", ctx do
      opts = Keyword.merge(base_opts(ctx), new: "n1", system: "be concise")
      {:ok, pid} = Agent.start_link(opts)

      assert Agent.get_state(pid, :id) == "n1"
      assert Agent.get_state(pid, :system) == "be concise"

      {:ok, loaded} = FileSystem.load("n1", base_path: ctx.tmp_dir)
      assert loaded.system == "be concise"
      assert loaded.model == model()
    end

    test "passes through :tree for forks", ctx do
      seed = Tree.push(%Tree{}, Message.new("seed"))

      opts = Keyword.merge(base_opts(ctx), new: "fork", tree: seed)
      {:ok, pid} = Agent.start_link(opts)

      assert Agent.get_state(pid, :tree) == seed

      # tree.jsonl populated from the seed
      {:ok, loaded} = FileSystem.load("fork", base_path: ctx.tmp_dir)
      assert Tree.size(loaded.tree) == 1
    end
  end

  describe "load mode" do
    test "hydrates tree / system / opts / meta from the store", ctx do
      tree = Tree.push(%Tree{}, Message.new("hello"))

      state_data = %{
        tree: tree,
        model: model(),
        system: "persisted prompt",
        opts: [temperature: 0.1],
        meta: %{title: "Persisted"}
      }

      :ok = FileSystem.save_tree("r1", tree, base_path: ctx.tmp_dir)
      :ok = FileSystem.save_state("r1", state_data, base_path: ctx.tmp_dir)

      opts = [model: model(), store: FileSystem, base_path: ctx.tmp_dir, load: "r1"]
      {:ok, pid} = Agent.start_link(opts)

      assert Agent.get_state(pid, :id) == "r1"
      assert Agent.get_state(pid, :system) == "persisted prompt"
      assert Agent.get_state(pid, :opts) == [temperature: 0.1]
      assert Agent.get_state(pid, :meta) == %{title: "Persisted"}
      assert Agent.get_state(pid, :tree) == tree
    end

    test "caller's :model and :system override persisted values and re-persist", ctx do
      persisted_model = {:anthropic, "claude-haiku-4-5"}
      override_model = {:anthropic, "claude-sonnet-4-5"}

      :ok =
        FileSystem.save_state(
          "ovr",
          %{
            tree: %Tree{},
            model: persisted_model,
            system: "old system",
            opts: [],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [
        store: FileSystem,
        base_path: ctx.tmp_dir,
        load: "ovr",
        model: override_model,
        system: "new system"
      ]

      {:ok, pid} = Agent.start_link(opts)

      # Caller wins
      live_model = Agent.get_state(pid, :model)
      assert live_model.id == "claude-sonnet-4-5"
      assert Agent.get_state(pid, :system) == "new system"

      # Overrides re-persisted on init save
      {:ok, loaded} = FileSystem.load("ovr", base_path: ctx.tmp_dir)
      assert loaded.model == override_model
      assert loaded.system == "new system"
    end

    test "caller's :opts replaces persisted :opts when given", ctx do
      :ok =
        FileSystem.save_state(
          "ovr",
          %{
            tree: %Tree{},
            model: model(),
            system: nil,
            opts: [temperature: 0.9],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [store: FileSystem, base_path: ctx.tmp_dir, load: "ovr", opts: [temperature: 0.1]]
      {:ok, pid} = Agent.start_link(opts)

      assert Agent.get_state(pid, :opts) == [temperature: 0.1]
    end

    test "persisted :opts are used when caller omits :opts", ctx do
      :ok =
        FileSystem.save_state(
          "ovr",
          %{
            tree: %Tree{},
            model: model(),
            system: nil,
            opts: [temperature: 0.9],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [store: FileSystem, base_path: ctx.tmp_dir, load: "ovr"]
      {:ok, pid} = Agent.start_link(opts)

      assert Agent.get_state(pid, :opts) == [temperature: 0.9]
    end
  end

  describe "lenient model resolution on load" do
    test "falls back to caller's :model when persisted ref unresolvable", ctx do
      unresolvable = {:nonexistent_provider, "no-such-model"}

      :ok =
        FileSystem.save_state(
          "lax",
          %{
            tree: %Tree{},
            model: unresolvable,
            system: nil,
            opts: [],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [store: FileSystem, base_path: ctx.tmp_dir, load: "lax", model: model()]
      {:ok, pid} = Agent.start_link(opts)

      live_model = Agent.get_state(pid, :model)
      assert live_model.id == "claude-haiku-4-5"
    end

    test "both persisted and caller unresolvable → :model_not_found", ctx do
      :ok =
        FileSystem.save_state(
          "lax",
          %{
            tree: %Tree{},
            model: {:nonexistent, "m"},
            system: nil,
            opts: [],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [
        store: FileSystem,
        base_path: ctx.tmp_dir,
        load: "lax",
        model: {:another_nonexistent, "m2"}
      ]

      assert_init_error(opts, :model_not_found)
    end

    test "caller omits :model and persisted ref resolves → persisted wins", ctx do
      :ok =
        FileSystem.save_state(
          "lax",
          %{
            tree: %Tree{},
            model: model(),
            system: nil,
            opts: [],
            meta: %{}
          },
          base_path: ctx.tmp_dir
        )

      opts = [store: FileSystem, base_path: ctx.tmp_dir, load: "lax"]
      {:ok, pid} = Agent.start_link(opts)

      live_model = Agent.get_state(pid, :model)
      assert live_model.id == "claude-haiku-4-5"
    end
  end

  describe "round-trip via Manager" do
    setup do
      start_supervised!(Omni.Agent.Manager)
      :ok
    end

    test "Manager.start_agent(store: s) → save → stop → Manager.start_agent(load: id) restores state",
         ctx do
      {:ok, pid1} =
        Omni.Agent.Manager.start_agent(
          model: model(),
          store: FileSystem,
          base_path: ctx.tmp_dir,
          system: "original",
          meta: %{title: "Round trip"}
        )

      id = Agent.get_state(pid1, :id)
      assert is_binary(id)

      :ok = Omni.Agent.Manager.stop_agent(id)

      {:ok, pid2} =
        Omni.Agent.Manager.start_agent(
          model: model(),
          store: FileSystem,
          base_path: ctx.tmp_dir,
          load: id
        )

      assert Agent.get_state(pid2, :id) == id
      assert Agent.get_state(pid2, :system) == "original"
      assert Agent.get_state(pid2, :meta) == %{title: "Round trip"}
    end
  end

  # Helper — a minimal serialised state_data used for seeding the store.
  defp sample_state do
    %{
      tree: %Tree{},
      model: {:anthropic, "claude-haiku-4-5"},
      system: nil,
      opts: [],
      meta: %{}
    }
  end
end
