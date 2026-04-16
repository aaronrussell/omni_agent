defmodule Omni.Agent.Store.FileSystemTest do
  use ExUnit.Case, async: true

  alias Omni.Agent.Store.FileSystem
  alias Omni.Agent.Tree
  alias Omni.{Message, Usage}

  @moduletag :tmp_dir

  defp user(text), do: Message.new(text)
  defp assistant(text), do: Message.new(role: :assistant, content: text)

  defp opts(%{tmp_dir: tmp_dir}), do: [base_path: tmp_dir]
  defp opts(%{tmp_dir: tmp_dir}, extra), do: Keyword.merge([base_path: tmp_dir], extra)

  defp sample_tree do
    %Tree{}
    |> Tree.push(user("hello"))
    |> Tree.push(assistant("world"), %Usage{input_tokens: 10, output_tokens: 20})
  end

  defp branching_tree do
    tree = %Tree{}
    {1, tree} = Tree.push_node(tree, user("r0"))
    {2, tree} = Tree.push_node(tree, assistant("a0"))
    {3, tree} = Tree.push_node(tree, user("r1"))
    {4, tree} = Tree.push_node(tree, assistant("a1"))

    {:ok, tree} = Tree.navigate(tree, 2)
    {5, tree} = Tree.push_node(tree, user("r1alt"))
    {_6, tree} = Tree.push_node(tree, assistant("a1alt"))

    tree
  end

  defp sample_state_data(attrs \\ %{}) do
    %{
      tree: sample_tree(),
      model: {:anthropic, "claude-sonnet-4-5-20250514"},
      system: "You are helpful.",
      opts: [temperature: 0.7, max_tokens: 1024],
      meta: %{title: "Hello world"}
    }
    |> Map.merge(Map.new(attrs))
  end

  defp read_meta_json(ctx, id) do
    Path.join([ctx.tmp_dir, id, "meta.json"])
    |> File.read!()
    |> JSON.decode!()
  end

  defp read_tree_jsonl(ctx, id) do
    Path.join([ctx.tmp_dir, id, "tree.jsonl"])
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  describe "save_tree + load round-trip" do
    test "saves and loads a simple tree", ctx do
      tree = sample_tree()

      assert :ok = FileSystem.save_tree("a1", tree, opts(ctx))
      assert {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))

      assert loaded == tree
    end

    test "saves and loads a branching tree", ctx do
      tree = branching_tree()

      assert :ok = FileSystem.save_tree("a1", tree, opts(ctx))
      assert {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))

      assert loaded == tree
      assert Tree.messages(loaded) == Tree.messages(tree)
    end

    test "preserves cursors and path", ctx do
      tree = branching_tree()

      :ok = FileSystem.save_tree("a1", tree, opts(ctx))
      {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))

      assert loaded.cursors == tree.cursors
      assert loaded.path == tree.path
    end

    test "preserves usage records on message nodes", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))
      assistant_node = Enum.find(Map.values(loaded.nodes), &(&1.message.role == :assistant))
      assert %Usage{input_tokens: 10, output_tokens: 20} = assistant_node.usage
    end
  end

  describe "incremental save via :new_node_ids" do
    test "appends only listed nodes to tree.jsonl", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      assert length(read_tree_jsonl(ctx, "a1")) == 2

      extended = Tree.push(tree, user("follow-up"))
      new_id = List.last(extended.path)

      :ok = FileSystem.save_tree("a1", extended, opts(ctx, new_node_ids: [new_id]))

      lines = read_tree_jsonl(ctx, "a1")
      assert length(lines) == 3

      {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))
      assert loaded == extended
    end

    test "full rewrite when :new_node_ids is absent", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      # Save again without :new_node_ids — same node count, not doubled
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      assert length(read_tree_jsonl(ctx, "a1")) == 2
    end

    test "empty :new_node_ids list appends nothing but still refreshes meta", ctx do
      tree = branching_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      meta1 = read_meta_json(ctx, "a1")
      Process.sleep(10)

      {:ok, navigated} = Tree.navigate(tree, 4)
      :ok = FileSystem.save_tree("a1", navigated, opts(ctx, new_node_ids: []))

      meta2 = read_meta_json(ctx, "a1")
      assert meta2["tree"]["path"] != meta1["tree"]["path"]
      assert meta2["updated_at"] != meta1["updated_at"]
      # No extra lines appended
      assert length(read_tree_jsonl(ctx, "a1")) == map_size(tree.nodes)
    end
  end

  describe "save_state + load round-trip" do
    test "saves and loads full state_data", ctx do
      state = sample_state_data()
      :ok = FileSystem.save_tree("a1", state.tree, opts(ctx))
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.tree == state.tree
      assert loaded.model == state.model
      assert loaded.system == state.system
      assert loaded.opts == state.opts
      assert loaded.meta == state.meta
    end

    test "save_state without a prior save_tree creates meta.json and load returns an empty tree",
         ctx do
      state = sample_state_data(%{tree: %Tree{}})
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      assert {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.tree == %Tree{}
      assert loaded.model == state.model
      assert loaded.system == state.system
    end

    test "save_state merges with existing meta (preserves tree path/cursors)", ctx do
      tree = branching_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))
      :ok = FileSystem.save_state("a1", sample_state_data(%{tree: tree}), opts(ctx))

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.tree == tree
    end

    test "round-trip preserves atoms, tuples, and nested structures in meta and opts", ctx do
      state =
        sample_state_data(%{
          opts: [temperature: 0.8, thinking: :high, stop: ["END", :done]],
          meta: %{model_hint: {:anthropic, "claude"}, nested: %{a: [:b, {:c, 1}]}}
        })

      :ok = FileSystem.save_tree("a1", state.tree, opts(ctx))
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.opts == state.opts
      assert loaded.meta == state.meta
    end

    test "nil system is persisted as nil", ctx do
      state = sample_state_data(%{system: nil})
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.system == nil
    end

    test "save_state updates model/system without touching tree on disk", ctx do
      tree = sample_tree()
      state = sample_state_data(%{tree: tree})
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      before_lines = read_tree_jsonl(ctx, "a1")

      updated = %{state | model: {:openai, "gpt-4"}, system: "You are precise."}
      :ok = FileSystem.save_state("a1", updated, opts(ctx))

      assert read_tree_jsonl(ctx, "a1") == before_lines

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.model == {:openai, "gpt-4"}
      assert loaded.system == "You are precise."
      assert loaded.tree == tree
    end
  end

  describe "meta.json file shape" do
    test "title is lifted to top level for readable inspection", ctx do
      state = sample_state_data(%{meta: %{title: "Readable Title"}})
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert meta["title"] == "Readable Title"
    end

    test "timestamps are ISO8601 strings", ctx do
      :ok = FileSystem.save_tree("a1", sample_tree(), opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(meta["created_at"])
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(meta["updated_at"])
    end

    test "tree.path and tree.cursors are stored as plain JSON", ctx do
      :ok = FileSystem.save_tree("a1", branching_tree(), opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert is_list(meta["tree"]["path"])
      assert Enum.all?(meta["tree"]["path"], &is_integer/1)
      assert is_list(meta["tree"]["cursors"])
      assert Enum.all?(meta["tree"]["cursors"], &match?([_, _], &1))
    end

    test "model is a plain JSON object with provider and id", ctx do
      state = sample_state_data()
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert meta["model"] == %{"provider" => "anthropic", "id" => "claude-sonnet-4-5-20250514"}
    end

    test "system is stored as a plain JSON string", ctx do
      :ok = FileSystem.save_state("a1", sample_state_data(), opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert meta["system"] == "You are helpful."
    end

    test "opts and meta are __etf wrappers", ctx do
      :ok = FileSystem.save_state("a1", sample_state_data(), opts(ctx))

      meta = read_meta_json(ctx, "a1")
      assert %{"__etf" => opts_blob} = meta["opts"]
      assert %{"__etf" => meta_blob} = meta["meta"]
      assert is_binary(opts_blob)
      assert is_binary(meta_blob)
    end

    test "title absent from meta means no top-level title field", ctx do
      state = sample_state_data(%{meta: %{}})
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      json = read_meta_json(ctx, "a1")
      refute Map.has_key?(json, "title")
    end
  end

  describe "timestamps" do
    test "created_at set on first save, updated_at advances", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      meta1 = read_meta_json(ctx, "a1")
      {:ok, created1, _} = DateTime.from_iso8601(meta1["created_at"])
      {:ok, updated1, _} = DateTime.from_iso8601(meta1["updated_at"])

      assert created1 == updated1

      Process.sleep(10)
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      meta2 = read_meta_json(ctx, "a1")
      {:ok, created2, _} = DateTime.from_iso8601(meta2["created_at"])
      {:ok, updated2, _} = DateTime.from_iso8601(meta2["updated_at"])

      assert created2 == created1
      assert DateTime.compare(updated2, updated1) == :gt
    end

    test "save_state after save_tree preserves created_at", ctx do
      :ok = FileSystem.save_tree("a1", sample_tree(), opts(ctx))
      meta1 = read_meta_json(ctx, "a1")

      Process.sleep(10)
      :ok = FileSystem.save_state("a1", sample_state_data(), opts(ctx))
      meta2 = read_meta_json(ctx, "a1")

      assert meta2["created_at"] == meta1["created_at"]
      assert meta2["updated_at"] != meta1["updated_at"]
    end
  end

  describe "atomic write for meta.json" do
    test "orphaned .tmp file from a prior crash is left alone and load still returns the previous good meta",
         ctx do
      :ok = FileSystem.save_state("a1", sample_state_data(), opts(ctx))
      good = read_meta_json(ctx, "a1")

      tmp_path = Path.join([ctx.tmp_dir, "a1", "meta.json.tmp"])
      File.write!(tmp_path, "{ truncated partial json")

      {:ok, loaded} = FileSystem.load("a1", opts(ctx))
      assert loaded.system == "You are helpful."
      assert read_meta_json(ctx, "a1") == good
    end

    test "successful write removes the .tmp file", ctx do
      :ok = FileSystem.save_state("a1", sample_state_data(), opts(ctx))

      tmp_path = Path.join([ctx.tmp_dir, "a1", "meta.json.tmp"])
      refute File.exists?(tmp_path)
    end
  end

  describe "tolerant load for tree.jsonl" do
    test "silently skips a truncated trailing line", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      tree_path = Path.join([ctx.tmp_dir, "a1", "tree.jsonl"])
      File.write!(tree_path, "{\"id\": \"truncated\"", [:append])

      {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))
      assert loaded == tree
    end

    test "silently skips a blank/garbage line", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree("a1", tree, opts(ctx))

      tree_path = Path.join([ctx.tmp_dir, "a1", "tree.jsonl"])
      File.write!(tree_path, "not-json\n", [:append])

      {:ok, %{tree: loaded}} = FileSystem.load("a1", opts(ctx))
      assert loaded.nodes == tree.nodes
    end
  end

  describe "list" do
    test "lists multiple sessions", ctx do
      :ok = FileSystem.save_tree("a1", sample_tree(), opts(ctx))
      :ok = FileSystem.save_tree("a2", sample_tree(), opts(ctx))

      {:ok, sessions} = FileSystem.list(opts(ctx))

      assert length(sessions) == 2
      ids = Enum.map(sessions, & &1.id)
      assert "a1" in ids
      assert "a2" in ids
    end

    test "returns empty list when no sessions exist", ctx do
      assert {:ok, []} = FileSystem.list(opts(ctx))
    end

    test "sorted by updated_at descending", ctx do
      :ok = FileSystem.save_tree("older", sample_tree(), opts(ctx))
      Process.sleep(10)
      :ok = FileSystem.save_tree("newer", sample_tree(), opts(ctx))

      {:ok, sessions} = FileSystem.list(opts(ctx))

      assert [%{id: "newer"}, %{id: "older"}] = sessions
    end

    test "includes title from meta without decoding the ETF bag", ctx do
      state = sample_state_data(%{meta: %{title: "My Chat"}})
      :ok = FileSystem.save_state("a1", state, opts(ctx))

      {:ok, [session]} = FileSystem.list(opts(ctx))
      assert session.title == "My Chat"
    end

    test "title is nil when not in meta", ctx do
      :ok = FileSystem.save_tree("a1", sample_tree(), opts(ctx))

      {:ok, [session]} = FileSystem.list(opts(ctx))
      assert session.title == nil
    end

    test "honours :limit", ctx do
      for i <- 1..5 do
        :ok = FileSystem.save_tree("sess_#{i}", sample_tree(), opts(ctx))
        Process.sleep(5)
      end

      {:ok, sessions} = FileSystem.list(opts(ctx, limit: 2))
      assert length(sessions) == 2
    end

    test "honours :offset", ctx do
      for i <- 1..4 do
        :ok = FileSystem.save_tree("sess_#{i}", sample_tree(), opts(ctx))
        Process.sleep(5)
      end

      {:ok, all} = FileSystem.list(opts(ctx))
      {:ok, skipped} = FileSystem.list(opts(ctx, offset: 2))

      assert length(skipped) == 2
      assert Enum.map(skipped, & &1.id) == Enum.map(Enum.drop(all, 2), & &1.id)
    end

    test ":limit and :offset together paginate through the full set", ctx do
      for i <- 1..5 do
        :ok = FileSystem.save_tree("sess_#{i}", sample_tree(), opts(ctx))
        Process.sleep(5)
      end

      {:ok, page1} = FileSystem.list(opts(ctx, limit: 2, offset: 0))
      {:ok, page2} = FileSystem.list(opts(ctx, limit: 2, offset: 2))
      {:ok, page3} = FileSystem.list(opts(ctx, limit: 2, offset: 4))

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1

      ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(Enum.uniq(ids)) == 5
    end
  end

  describe "delete" do
    test "deletes a session", ctx do
      :ok = FileSystem.save_tree("a1", sample_tree(), opts(ctx))
      assert {:ok, _} = FileSystem.load("a1", opts(ctx))

      assert :ok = FileSystem.delete("a1", opts(ctx))
      assert {:error, :not_found} = FileSystem.load("a1", opts(ctx))
    end

    test "deleting non-existent session returns :ok", ctx do
      assert :ok = FileSystem.delete("nonexistent", opts(ctx))
    end
  end

  describe "load errors" do
    test "returns error for non-existent session", ctx do
      assert {:error, :not_found} = FileSystem.load("nonexistent", opts(ctx))
    end
  end
end
