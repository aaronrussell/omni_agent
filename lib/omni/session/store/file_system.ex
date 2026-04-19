defmodule Omni.Session.Store.FileSystem do
  @moduledoc """
  Reference `Omni.Session.Store` adapter using plain files on disk.

  Designed for local development, single-node deployments, and as a
  worked example of the adapter contract. Each session lives in its own
  directory with two files:

      <base_path>/
        <session_id>/
          nodes.jsonl     # tree nodes, one JSON-encoded node per line
          session.json    # path, cursors, state fields, timestamps

  `nodes.jsonl` is append-only when `save_tree/4` is called with a
  `:new_node_ids` hint; otherwise it's rewritten from the full node set.
  `session.json` is a single merged file written by both `save_tree` and
  `save_state` — the two callbacks write disjoint keys, so the merge is
  read-modify-write with no conflict resolution.

  ## Configuration

  `:base_path` is required; the adapter raises `ArgumentError` if absent.

      store = {Omni.Session.Store.FileSystem, base_path: "/var/data/sessions"}

  ## Encoding

  | Field | Encoding |
  |---|---|
  | node `message`, `usage` | `Omni.Codec.encode/1` |
  | `path` | JSON array of integers |
  | `cursors` | JSON array of `[parent_id, child_id]` pairs |
  | `title`, `system` | plain JSON string or `null` |
  | `model` | `[provider_string, model_id]` |
  | `opts` | `Omni.Codec.encode_term/1` wrapper |
  | `created_at`, `updated_at` | ISO8601 strings |
  """

  @behaviour Omni.Session.Store

  alias Omni.Codec
  alias Omni.Session.Tree

  @impl true
  def save_tree(cfg, id, %Tree{} = tree, opts \\ []) do
    dir = session_dir(cfg, id)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_nodes(dir, tree, Keyword.get(opts, :new_node_ids)),
         :ok <-
           update_session_json(dir, %{
             "path" => tree.path,
             "cursors" => encode_cursors(tree.cursors)
           }) do
      :ok
    end
  end

  @impl true
  def save_state(cfg, id, state_map, _opts \\ []) when is_map(state_map) do
    dir = session_dir(cfg, id)

    with :ok <- File.mkdir_p(dir),
         :ok <- update_session_json(dir, encode_state(state_map)) do
      :ok
    end
  end

  @impl true
  def load(cfg, id, _opts \\ []) do
    dir = session_dir(cfg, id)

    case read_session_json(session_path(dir)) do
      {:ok, session_json} ->
        nodes = read_nodes(dir)
        path = session_json["path"] || []
        cursors = decode_cursors(session_json["cursors"] || [])
        tree = Tree.new(nodes: nodes, path: path, cursors: cursors)
        {:ok, tree, decode_state(session_json)}

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def list(cfg, opts \\ []) do
    base = base_path(cfg)

    sessions =
      case File.ls(base) do
        {:ok, entries} ->
          entries
          |> Enum.map(&read_summary(base, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
          |> Enum.drop(Keyword.get(opts, :offset, 0))
          |> maybe_take(Keyword.get(opts, :limit))

        {:error, :enoent} ->
          []
      end

    {:ok, sessions}
  end

  @impl true
  def delete(cfg, id, _opts \\ []) do
    case File.rm_rf(session_dir(cfg, id)) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  # ── Paths ──────────────────────────────────────────────────────────

  defp base_path(cfg) do
    case Keyword.fetch(cfg, :base_path) do
      {:ok, path} ->
        path

      :error ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a :base_path in its config"
    end
  end

  defp session_dir(cfg, id), do: Path.join(base_path(cfg), id)
  defp session_path(dir), do: Path.join(dir, "session.json")
  defp nodes_path(dir), do: Path.join(dir, "nodes.jsonl")

  # ── Nodes file ─────────────────────────────────────────────────────

  # nil = full rewrite from the tree's node set
  defp write_nodes(dir, %Tree{nodes: nodes}, nil) do
    lines =
      nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&(encode_node(&1) <> "\n"))

    File.write(nodes_path(dir), lines)
  end

  # [] = navigation-only save, don't touch the nodes file
  defp write_nodes(_dir, _tree, []), do: :ok

  # list of ids = append just those nodes
  defp write_nodes(dir, %Tree{nodes: nodes}, ids) when is_list(ids) do
    lines =
      ids
      |> Enum.map(&Map.fetch!(nodes, &1))
      |> Enum.map(&(encode_node(&1) <> "\n"))

    File.write(nodes_path(dir), lines, [:append])
  end

  defp read_nodes(dir) do
    path = nodes_path(dir)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&decode_node/1)
    else
      []
    end
  end

  defp encode_node(node) do
    JSON.encode!(%{
      "id" => node.id,
      "parent_id" => node.parent_id,
      "message" => Codec.encode(node.message),
      "usage" => if(node.usage, do: Codec.encode(node.usage), else: nil)
    })
  end

  defp decode_node(line) do
    map = JSON.decode!(line)
    {:ok, message} = Codec.decode(map["message"])

    usage =
      case map["usage"] do
        nil ->
          nil

        encoded ->
          {:ok, u} = Codec.decode(encoded)
          u
      end

    %{
      id: map["id"],
      parent_id: map["parent_id"],
      message: message,
      usage: usage
    }
  end

  # ── session.json ───────────────────────────────────────────────────

  defp update_session_json(dir, updates) do
    path = session_path(dir)
    now_iso = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    existing =
      case read_session_json(path) do
        {:ok, map} -> map
        :error -> %{"created_at" => now_iso}
      end

    merged =
      existing
      |> Map.merge(updates)
      |> Map.put("updated_at", now_iso)

    File.write(path, JSON.encode!(merged))
  end

  defp read_session_json(path) do
    case File.read(path) do
      {:ok, json} ->
        try do
          {:ok, JSON.decode!(json)}
        rescue
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  end

  # ── State encoding ─────────────────────────────────────────────────

  defp encode_state(state_map) do
    Enum.reduce(state_map, %{}, fn
      {:model, {provider, model_id}}, acc when is_atom(provider) and is_binary(model_id) ->
        Map.put(acc, "model", [Atom.to_string(provider), model_id])

      {:system, value}, acc ->
        Map.put(acc, "system", value)

      {:title, value}, acc ->
        Map.put(acc, "title", value)

      {:opts, opts}, acc when is_list(opts) ->
        Map.put(acc, "opts", Codec.encode_term(opts))

      _, acc ->
        acc
    end)
  end

  defp decode_state(session_json) do
    %{}
    |> decode_state_key(session_json, "model", :model, &decode_model/1)
    |> decode_state_key(session_json, "system", :system, & &1)
    |> decode_state_key(session_json, "title", :title, & &1)
    |> decode_state_key(session_json, "opts", :opts, &decode_opts/1)
  end

  defp decode_state_key(acc, json, json_key, atom_key, decoder) do
    case Map.fetch(json, json_key) do
      {:ok, value} -> Map.put(acc, atom_key, decoder.(value))
      :error -> acc
    end
  end

  defp decode_model([provider_str, model_id])
       when is_binary(provider_str) and is_binary(model_id) do
    {String.to_existing_atom(provider_str), model_id}
  end

  defp decode_opts(encoded) do
    {:ok, opts} = Codec.decode_term(encoded)
    opts
  end

  # ── Cursors encoding (JSON can't key maps on integers) ─────────────

  defp encode_cursors(cursors), do: Enum.map(cursors, fn {k, v} -> [k, v] end)
  defp decode_cursors(list), do: Map.new(list, fn [k, v] -> {k, v} end)

  # ── List summary ───────────────────────────────────────────────────

  defp read_summary(base, entry) do
    with {:ok, json} <- File.read(Path.join([base, entry, "session.json"])),
         {:ok, map} <- safe_decode(json),
         {:ok, created_at, _} <- DateTime.from_iso8601(Map.get(map, "created_at", "")),
         {:ok, updated_at, _} <- DateTime.from_iso8601(Map.get(map, "updated_at", "")) do
      %{
        id: entry,
        title: Map.get(map, "title"),
        created_at: created_at,
        updated_at: updated_at
      }
    else
      _ -> nil
    end
  end

  defp safe_decode(json) do
    {:ok, JSON.decode!(json)}
  rescue
    _ -> :error
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, limit), do: Enum.take(list, limit)
end
