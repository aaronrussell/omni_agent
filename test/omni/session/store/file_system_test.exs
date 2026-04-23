defmodule Omni.Session.Store.FileSystemTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Omni.{Message, Usage}
  alias Omni.Session.Tree
  alias Omni.Session.Store.FileSystem

  @moduletag :tmp_dir

  defp user(text), do: Message.new(text)
  defp assistant(text), do: Message.new(role: :assistant, content: text)

  defp cfg(%{tmp_dir: dir}), do: [base_path: dir]

  defp sample_tree do
    %Tree{}
    |> Tree.push(user("hello"))
    |> Tree.push(assistant("world"), %Usage{input_tokens: 10, output_tokens: 20})
  end

  # A branching tree mirroring the example in tree_test.exs:
  #   1 ── 2 ── 3 ── 4 ── 5 ── 6
  #                   │
  #                   └── 7 ── 8     (active path: [1,2,3,4,7,8])
  defp branching_tree do
    tree = %Tree{}
    {1, tree} = Tree.push_node(tree, user("r0"))
    {2, tree} = Tree.push_node(tree, assistant("a0"))
    {3, tree} = Tree.push_node(tree, user("r1"))
    {4, tree} = Tree.push_node(tree, assistant("a1"))
    {5, tree} = Tree.push_node(tree, user("r2"))
    {6, tree} = Tree.push_node(tree, assistant("a2"))

    {:ok, tree} = Tree.navigate(tree, 4)
    {7, tree} = Tree.push_node(tree, user("r3alt"))
    {_8, tree} = Tree.push_node(tree, assistant("a3alt"))

    tree
  end

  defp read_session_json(ctx, id) do
    Path.join([ctx.tmp_dir, id, "session.json"])
    |> File.read!()
    |> JSON.decode!()
  end

  defp read_nodes_jsonl(ctx, id) do
    Path.join([ctx.tmp_dir, id, "nodes.jsonl"])
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  describe "config validation" do
    test "raises when :base_path is missing" do
      assert_raise ArgumentError, ~r/base_path/, fn ->
        FileSystem.save_tree([], "s1", %Tree{})
      end
    end
  end

  describe "save_tree + load round-trip" do
    test "linear tree", ctx do
      tree = sample_tree()

      assert :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)
      assert {:ok, loaded, %{}} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == tree
    end

    test "branching tree", ctx do
      tree = branching_tree()

      assert :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)
      assert {:ok, loaded, %{}} = FileSystem.load(cfg(ctx), "s1")

      assert loaded == tree
      assert Tree.messages(loaded) == Tree.messages(tree)
    end

    test "preserves path and cursors", ctx do
      tree = branching_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      {:ok, loaded, _} = FileSystem.load(cfg(ctx), "s1")
      assert loaded.path == tree.path
      assert loaded.cursors == tree.cursors
    end

    test "preserves usage on nodes", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      {:ok, loaded, _} = FileSystem.load(cfg(ctx), "s1")
      assistant_node = Enum.find(Map.values(loaded.nodes), &(&1.message.role == :assistant))
      assert %Usage{input_tokens: 10, output_tokens: 20} = assistant_node.usage
    end
  end

  describe "incremental save via :new_node_ids" do
    test "appends only listed nodes", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)
      assert length(read_nodes_jsonl(ctx, "s1")) == 2

      extended = Tree.push(tree, user("follow-up"))
      new_id = List.last(extended.path)

      :ok = FileSystem.save_tree(cfg(ctx), "s1", extended, new_node_ids: [new_id])
      assert length(read_nodes_jsonl(ctx, "s1")) == 3

      {:ok, loaded, _} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == extended
    end

    test "full rewrite when :new_node_ids is absent", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      assert length(read_nodes_jsonl(ctx, "s1")) == 2
    end

    test ":new_node_ids: [] leaves nodes.jsonl untouched but refreshes session.json", ctx do
      tree = branching_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      meta1 = read_session_json(ctx, "s1")
      nodes1 = read_nodes_jsonl(ctx, "s1")

      Process.sleep(50)
      {:ok, navigated} = Tree.navigate(tree, 6)
      :ok = FileSystem.save_tree(cfg(ctx), "s1", navigated, new_node_ids: [])

      meta2 = read_session_json(ctx, "s1")
      nodes2 = read_nodes_jsonl(ctx, "s1")

      assert nodes1 == nodes2
      assert meta2["path"] != meta1["path"]
      assert meta2["updated_at"] != meta1["updated_at"]
    end
  end

  describe "save_state semantics" do
    test "full map round-trips", ctx do
      state = %{
        model: {:anthropic, "claude-sonnet-4-5"},
        system: "You are helpful.",
        opts: [temperature: 0.7, max_tokens: 4096],
        title: "My chat"
      }

      :ok = FileSystem.save_state(cfg(ctx), "s1", state)

      {:ok, %Tree{}, loaded} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == state
    end

    test "partial maps persist only the keys given", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "Title only"})

      {:ok, _, loaded} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == %{title: "Title only"}
    end

    test "subsequent partial call composes — older keys survive", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "T"})
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{system: "S"})

      {:ok, _, loaded} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == %{title: "T", system: "S"}
    end

    test "same key overwrites", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "Old"})
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "New"})

      {:ok, _, loaded} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == %{title: "New"}
    end

    test "nil values round-trip (not dropped)", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: nil, system: nil})

      {:ok, _, loaded} = FileSystem.load(cfg(ctx), "s1")
      assert loaded == %{title: nil, system: nil}
    end
  end

  describe "save_tree + save_state coexistence" do
    test "save_tree then save_state keeps both", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "Hi"})

      {:ok, loaded_tree, loaded_state} = FileSystem.load(cfg(ctx), "s1")
      assert loaded_tree == tree
      assert loaded_state == %{title: "Hi"}
    end

    test "save_state then save_tree keeps both", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "Hi"})
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      {:ok, loaded_tree, loaded_state} = FileSystem.load(cfg(ctx), "s1")
      assert loaded_tree == tree
      assert loaded_state == %{title: "Hi"}
    end

    test "later save_tree does not clobber prior state keys", ctx do
      state = %{model: {:anthropic, "claude"}, title: "T"}
      :ok = FileSystem.save_state(cfg(ctx), "s1", state)

      updated = Tree.push(sample_tree(), user("more"))
      :ok = FileSystem.save_tree(cfg(ctx), "s1", updated)

      {:ok, _, loaded_state} = FileSystem.load(cfg(ctx), "s1")
      assert loaded_state == state
    end
  end

  describe "session.json file shape" do
    test "model is a plain JSON array [provider, id]", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{model: {:anthropic, "claude-sonnet-4-5"}})

      assert read_session_json(ctx, "s1")["model"] == ["anthropic", "claude-sonnet-4-5"]
    end

    test "title and system are plain JSON strings", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "My chat", system: "Helpful."})

      meta = read_session_json(ctx, "s1")
      assert meta["title"] == "My chat"
      assert meta["system"] == "Helpful."
    end

    test "opts is an ETF wrapper", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{opts: [temperature: 0.5]})

      assert %{"__etf" => blob} = read_session_json(ctx, "s1")["opts"]
      assert is_binary(blob)
    end

    test "timestamps are ISO8601 strings", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      meta = read_session_json(ctx, "s1")
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(meta["created_at"])
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(meta["updated_at"])
    end

    test "path and cursors are plain JSON", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", branching_tree())

      meta = read_session_json(ctx, "s1")
      assert is_list(meta["path"])
      assert Enum.all?(meta["path"], &is_integer/1)
      assert is_list(meta["cursors"])
      assert Enum.all?(meta["cursors"], &match?([_, _], &1))
    end

    test "created_at set on first write, updated_at advances on next", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      meta1 = read_session_json(ctx, "s1")
      {:ok, created1, _} = DateTime.from_iso8601(meta1["created_at"])
      {:ok, updated1, _} = DateTime.from_iso8601(meta1["updated_at"])
      assert created1 == updated1

      Process.sleep(50)
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "x"})

      meta2 = read_session_json(ctx, "s1")
      {:ok, created2, _} = DateTime.from_iso8601(meta2["created_at"])
      {:ok, updated2, _} = DateTime.from_iso8601(meta2["updated_at"])
      assert created2 == created1
      assert DateTime.compare(updated2, updated1) == :gt
    end
  end

  describe "load edge cases" do
    test "returns :not_found for a session that doesn't exist", ctx do
      assert {:error, :not_found} = FileSystem.load(cfg(ctx), "nope")
    end

    test "returns empty tree when only save_state was called", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "early"})

      assert {:ok, %Tree{nodes: nodes, path: [], cursors: %{}}, state} =
               FileSystem.load(cfg(ctx), "s1")

      assert nodes == %{}
      assert state == %{title: "early"}
    end

    test "returns empty state_map when only save_tree was called", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      assert {:ok, _tree, state} = FileSystem.load(cfg(ctx), "s1")
      assert state == %{}
    end
  end

  describe "list/2" do
    test "returns empty when no sessions exist", ctx do
      assert {:ok, []} = FileSystem.list(cfg(ctx))
    end

    test "returns empty when base_path does not exist", ctx do
      assert {:ok, []} = FileSystem.list(base_path: Path.join(ctx.tmp_dir, "missing"))
    end

    test "lists multiple sessions sorted by updated_at descending", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "older", sample_tree())
      Process.sleep(50)
      :ok = FileSystem.save_tree(cfg(ctx), "newer", sample_tree())

      {:ok, [first, second]} = FileSystem.list(cfg(ctx))
      assert first.id == "newer"
      assert second.id == "older"
    end

    test "includes title pulled from session.json without decoding opts", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "Only title", opts: [x: :y]})

      {:ok, [%{id: "s1", title: "Only title"}]} = FileSystem.list(cfg(ctx))
    end

    test "title is nil when not set", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      {:ok, [%{title: nil}]} = FileSystem.list(cfg(ctx))
    end

    test "includes created_at and updated_at as DateTimes", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      {:ok, [info]} = FileSystem.list(cfg(ctx))
      assert %DateTime{} = info.created_at
      assert %DateTime{} = info.updated_at
    end

    test "honours :limit", ctx do
      for i <- 1..5 do
        :ok = FileSystem.save_tree(cfg(ctx), "s#{i}", sample_tree())
        Process.sleep(50)
      end

      {:ok, list} = FileSystem.list(cfg(ctx), limit: 2)
      assert length(list) == 2
    end

    test "honours :offset", ctx do
      for i <- 1..4 do
        :ok = FileSystem.save_tree(cfg(ctx), "s#{i}", sample_tree())
        Process.sleep(50)
      end

      {:ok, all} = FileSystem.list(cfg(ctx))
      {:ok, skipped} = FileSystem.list(cfg(ctx), offset: 2)

      assert length(skipped) == 2
      assert Enum.map(skipped, & &1.id) == Enum.map(Enum.drop(all, 2), & &1.id)
    end

    test ":limit and :offset paginate the full set", ctx do
      for i <- 1..5 do
        :ok = FileSystem.save_tree(cfg(ctx), "s#{i}", sample_tree())
        Process.sleep(50)
      end

      {:ok, page1} = FileSystem.list(cfg(ctx), limit: 2, offset: 0)
      {:ok, page2} = FileSystem.list(cfg(ctx), limit: 2, offset: 2)
      {:ok, page3} = FileSystem.list(cfg(ctx), limit: 2, offset: 4)

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1

      ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(Enum.uniq(ids)) == 5
    end

    test "skips entries without a readable session.json", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "ok_session", sample_tree())
      File.mkdir_p!(Path.join(ctx.tmp_dir, "broken"))
      File.write!(Path.join([ctx.tmp_dir, "broken", "session.json"]), "{not-json")

      {:ok, list} = FileSystem.list(cfg(ctx))
      assert Enum.map(list, & &1.id) == ["ok_session"]
    end
  end

  describe "delete/3" do
    test "removes a session", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())
      assert {:ok, _, _} = FileSystem.load(cfg(ctx), "s1")

      assert :ok = FileSystem.delete(cfg(ctx), "s1")
      assert {:error, :not_found} = FileSystem.load(cfg(ctx), "s1")
    end

    test "is idempotent on a non-existent session", ctx do
      assert :ok = FileSystem.delete(cfg(ctx), "never_existed")
    end
  end

  describe "exists?/2" do
    test "returns true for a persisted session", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "here", sample_tree())
      assert FileSystem.exists?(cfg(ctx), "here")
    end

    test "returns true even for a state-only session (no tree yet)", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "here", %{title: "t"})
      assert FileSystem.exists?(cfg(ctx), "here")
    end

    test "returns false when no session directory exists", ctx do
      refute FileSystem.exists?(cfg(ctx), "missing")
    end

    test "returns false for a directory without session.json", ctx do
      File.mkdir_p!(Path.join(ctx.tmp_dir, "empty"))
      refute FileSystem.exists?(cfg(ctx), "empty")
    end

    test "returns false after delete", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "here", sample_tree())
      :ok = FileSystem.delete(cfg(ctx), "here")
      refute FileSystem.exists?(cfg(ctx), "here")
    end
  end

  describe "durability" do
    test "load tolerates a torn trailing line in nodes.jsonl", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      # Simulate a crash mid-append: a fragment with no closing brace and
      # no trailing newline.
      nodes_path = Path.join([ctx.tmp_dir, "s1", "nodes.jsonl"])
      File.write!(nodes_path, ~s({"id":99,"parent_id":1,"mess), [:append])

      log =
        capture_log(fn ->
          assert {:ok, loaded, _state} = FileSystem.load(cfg(ctx), "s1")
          assert loaded == tree
        end)

      assert log =~ "skipping malformed line"
      assert log =~ "nodes.jsonl"
    end

    test "load tolerates a malformed middle line in nodes.jsonl", ctx do
      tree = sample_tree()
      :ok = FileSystem.save_tree(cfg(ctx), "s1", tree)

      # Simulate torn-then-successful-append: the bad line is now in the
      # middle of the file. The uniform-skip rule recovers both valid
      # entries.
      nodes_path = Path.join([ctx.tmp_dir, "s1", "nodes.jsonl"])
      original = File.read!(nodes_path)
      [line1, line2 | _] = String.split(original, "\n", trim: true)
      torn = ~s({"id":99,"parent_id":1,"mess)
      File.write!(nodes_path, [line1, "\n", torn, "\n", line2, "\n"])

      log =
        capture_log(fn ->
          assert {:ok, loaded, _state} = FileSystem.load(cfg(ctx), "s1")
          assert map_size(loaded.nodes) == 2
        end)

      assert log =~ "skipping malformed line"
    end

    @tag :capture_log
    test "load returns :not_found when session.json is truncated", ctx do
      :ok = FileSystem.save_tree(cfg(ctx), "s1", sample_tree())

      # Simulate a crash between File.write's truncate and flush.
      session_path = Path.join([ctx.tmp_dir, "s1", "session.json"])
      File.write!(session_path, "")

      assert {:error, :not_found} = FileSystem.load(cfg(ctx), "s1")
    end

    test "atomic write overwrites a stale .tmp from a previous crashed write", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "first"})

      # Simulate a crash between tmp-write and rename: a stale .tmp is
      # left next to session.json. The next save must succeed and not
      # leave the stale content behind.
      session_path = Path.join([ctx.tmp_dir, "s1", "session.json"])
      tmp_path = session_path <> ".tmp"
      File.write!(tmp_path, "{broken junk")
      original = File.read!(session_path)

      # Live file is still intact before the next save.
      assert original != ""
      assert {:ok, _tree, %{title: "first"}} = FileSystem.load(cfg(ctx), "s1")

      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "second"})

      {:ok, _tree, state} = FileSystem.load(cfg(ctx), "s1")
      assert state == %{title: "second"}
      refute File.exists?(tmp_path)
    end

    test "two sequential save_state calls both land", ctx do
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{title: "T"})
      :ok = FileSystem.save_state(cfg(ctx), "s1", %{system: "S"})

      {:ok, _tree, state} = FileSystem.load(cfg(ctx), "s1")
      assert state == %{title: "T", system: "S"}
    end
  end
end
