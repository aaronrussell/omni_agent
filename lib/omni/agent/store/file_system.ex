defmodule Omni.Agent.Store.FileSystem do
  @moduledoc """
  Filesystem-based `Omni.Agent.Store` adapter using JSON and JSONL.

  Persists conversation trees as append-only JSONL and agent configuration
  as JSON. Supports incremental saves: when `:new_node_ids` is passed to
  `save_tree/3`, only those nodes are appended to `tree.jsonl` rather than
  rewriting the file.

  ## Storage layout

      {base_path}/
        {agent_id}/
          tree.jsonl     # one line per tree node
          meta.json      # timestamps, title, tree path/cursors, config

  ## meta.json shape

      {
        "title": "Optional title",
        "created_at": "2026-04-16T12:00:00Z",
        "updated_at": "2026-04-16T12:34:56Z",
        "tree": {
          "path": [1, 3, 5],
          "cursors": [[1, 3], [3, 5]]
        },
        "model": {"provider": "anthropic", "id": "claude-..."},
        "system": "You are ...",
        "opts": {"__etf": "<base64>"},
        "meta": {"__etf": "<base64>"}
      }

  `title` is duplicated at the top level for human inspection; the
  canonical value lives inside the `meta` ETF blob. The encoder is the
  only writer, so the two cannot drift.

  `model` is stored as a plain JSON object (`{provider, id}`) to keep the
  file readable. `system` is a plain string. `opts` and `meta` are ETF
  blobs via `Omni.Codec.encode_term/1`, which preserves atoms, tuples,
  and keyword ordering losslessly.

  ## Durability

  `meta.json` is written atomically: the encoder writes to `meta.json.tmp`
  and then renames into place. POSIX rename on the same filesystem is
  atomic, so a crash mid-write leaves the previous `meta.json` intact.

  `tree.jsonl` is append-only. On load, lines that fail to parse are
  silently skipped — the realistic failure mode is a writer crash
  truncating the trailing line.

  ## Configuration

  The base path defaults to `priv/omni_agent/sessions` relative to the
  current working directory. Override with:

      config :omni_agent, Omni.Agent.Store.FileSystem, base_path: "/custom/path"

  Or pass `:base_path` in the opts of any callback.
  """

  @behaviour Omni.Agent.Store

  alias Omni.Codec
  alias Omni.Agent.Tree

  @impl true
  def save_tree(id, %Tree{} = tree, opts \\ []) do
    dir = agent_dir(id, opts)
    tree_path = Path.join(dir, "tree.jsonl")
    meta_path = Path.join(dir, "meta.json")

    with :ok <- File.mkdir_p(dir),
         :ok <- write_tree_file(tree_path, tree, Keyword.get(opts, :new_node_ids)),
         :ok <- update_meta(meta_path, %{tree: %{path: tree.path, cursors: tree.cursors}}) do
      :ok
    end
  end

  @impl true
  def save_state(id, state_data, opts \\ []) do
    dir = agent_dir(id, opts)
    meta_path = Path.join(dir, "meta.json")

    with :ok <- File.mkdir_p(dir) do
      update_meta(meta_path, Map.take(state_data, [:model, :system, :opts, :meta]))
    end
  end

  @impl true
  def load(id, opts \\ []) do
    dir = agent_dir(id, opts)
    tree_path = Path.join(dir, "tree.jsonl")
    meta_path = Path.join(dir, "meta.json")

    case read_meta_file(meta_path) do
      :error ->
        {:error, :not_found}

      {:ok, meta} ->
        tree = load_tree(tree_path, meta)

        {:ok,
         %{
           tree: tree,
           model: meta.model,
           system: meta.system,
           opts: meta.opts,
           meta: meta.meta
         }}
    end
  end

  @impl true
  def list(opts \\ []) do
    base = base_path(opts)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    summaries =
      case File.ls(base) do
        {:ok, entries} ->
          entries
          |> Enum.map(&read_summary(base, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
          |> Enum.drop(offset)
          |> maybe_take(limit)

        {:error, :enoent} ->
          []
      end

    {:ok, summaries}
  end

  @impl true
  def delete(id, opts \\ []) do
    dir = agent_dir(id, opts)

    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  # ── Tree file ──────────────────────────────────────────────────────

  defp write_tree_file(path, %Tree{nodes: nodes}, nil) do
    lines =
      nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&(encode_node(&1) <> "\n"))

    File.write(path, lines)
  end

  defp write_tree_file(path, %Tree{nodes: nodes}, new_ids) when is_list(new_ids) do
    lines =
      new_ids
      |> Enum.map(&Map.fetch!(nodes, &1))
      |> Enum.map(&(encode_node(&1) <> "\n"))

    File.write(path, lines, [:append])
  end

  defp encode_node(node) do
    JSON.encode!(%{
      "id" => node.id,
      "parent_id" => node.parent_id,
      "message" => Codec.encode(node.message),
      "usage" => if(node.usage, do: Codec.encode(node.usage), else: nil)
    })
  end

  defp load_tree(path, meta) do
    nodes =
      if File.exists?(path) do
        path
        |> File.stream!()
        |> Stream.flat_map(&safe_decode_node/1)
        |> Enum.to_list()
      else
        []
      end

    Tree.new(nodes: nodes, path: meta.tree.path, cursors: meta.tree.cursors)
  end

  # Silent skip for unparseable lines — protects against a trailing line
  # truncated by a crash mid-append. Middle-line corruption is rare enough
  # for an append-only single-writer file that we'd rather surface any
  # downstream breakage than mask it with repair logic.
  defp safe_decode_node(line) do
    [decode_node(line)]
  rescue
    _ -> []
  end

  defp decode_node(line) do
    map = JSON.decode!(line)
    {:ok, message} = Codec.decode(map["message"])

    usage =
      case map["usage"] do
        nil -> nil
        encoded -> with {:ok, u} <- Codec.decode(encoded), do: u
      end

    %{
      id: map["id"],
      parent_id: map["parent_id"],
      message: message,
      usage: usage
    }
  end

  # ── Meta file ──────────────────────────────────────────────────────

  defp update_meta(path, updates) do
    now = DateTime.utc_now()

    base =
      case read_meta_file(path) do
        {:ok, meta} -> %{meta | updated_at: now}
        :error -> %{empty_meta() | created_at: now, updated_at: now}
      end

    meta = Map.merge(base, updates)
    write_meta_atomic(path, meta)
  end

  defp empty_meta do
    %{
      created_at: nil,
      updated_at: nil,
      title: nil,
      tree: %{path: [], cursors: %{}},
      model: nil,
      system: nil,
      opts: [],
      meta: %{}
    }
  end

  defp read_meta_file(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, decode_meta(json)}
      {:error, _} -> :error
    end
  end

  defp write_meta_atomic(path, meta) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, encode_meta(meta)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp encode_meta(meta) do
    base = %{
      "created_at" => datetime_to_iso8601(meta.created_at),
      "updated_at" => datetime_to_iso8601(meta.updated_at),
      "tree" => %{
        "path" => meta.tree.path,
        "cursors" => encode_cursors(meta.tree.cursors)
      },
      "model" => encode_model(meta.model),
      "system" => meta.system,
      "opts" => Codec.encode_term(meta.opts),
      "meta" => Codec.encode_term(meta.meta)
    }

    case Map.get(meta.meta, :title) do
      nil -> base
      title -> Map.put(base, "title", title)
    end
    |> JSON.encode!()
  end

  defp decode_meta(json) do
    map = JSON.decode!(json)
    {:ok, opts} = Codec.decode_term(map["opts"] || Codec.encode_term([]))
    {:ok, meta} = Codec.decode_term(map["meta"] || Codec.encode_term(%{}))

    %{
      created_at: decode_datetime(map["created_at"]),
      updated_at: decode_datetime(map["updated_at"]),
      title: map["title"],
      tree: %{
        path: map["tree"]["path"] || [],
        cursors: decode_cursors(map["tree"]["cursors"] || [])
      },
      model: decode_model(map["model"]),
      system: map["system"],
      opts: opts,
      meta: meta
    }
  end

  defp encode_model(nil), do: nil

  defp encode_model({provider, id}) when is_atom(provider) and is_binary(id) do
    %{"provider" => Atom.to_string(provider), "id" => id}
  end

  defp decode_model(nil), do: nil

  defp decode_model(%{"provider" => provider, "id" => id}) do
    {String.to_existing_atom(provider), id}
  end

  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp decode_datetime(nil), do: nil

  defp decode_datetime(str) when is_binary(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

  defp encode_cursors(cursors), do: Enum.map(cursors, fn {k, v} -> [k, v] end)
  defp decode_cursors(list), do: Map.new(list, fn [k, v] -> {k, v} end)

  # ── Listing ────────────────────────────────────────────────────────

  defp read_summary(base, entry) do
    meta_path = Path.join([base, entry, "meta.json"])

    case File.read(meta_path) do
      {:ok, json} ->
        map = JSON.decode!(json)

        %{
          id: entry,
          title: map["title"],
          created_at: decode_datetime(map["created_at"]),
          updated_at: decode_datetime(map["updated_at"])
        }

      {:error, _} ->
        nil
    end
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, limit), do: Enum.take(list, limit)

  # ── Paths ──────────────────────────────────────────────────────────

  defp agent_dir(id, opts), do: Path.join(base_path(opts), id)

  defp base_path(opts) do
    Keyword.get_lazy(opts, :base_path, fn ->
      Application.get_env(:omni_agent, __MODULE__, [])
      |> Keyword.get(:base_path, default_base_path())
    end)
  end

  defp default_base_path do
    Path.join(["priv", "omni_agent", "sessions"])
  end
end
