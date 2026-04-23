defmodule Omni.Session.Tree do
  @moduledoc """
  A branching message tree used by `Omni.Session` to store conversation history.

  Each node holds a message and an optional parent pointer, forming a tree where
  linear conversations are the common case and branches represent alternate replies
  or edits.

  ## Active path and cursors

  An **active path** acts as a cursor through the tree — `push/3` always appends
  to the head of this path, and `navigate/2` moves it to a different branch.

  Both `push/3` and `navigate/2` record **cursors** that track which child was
  most recently selected at a given parent. `push/3` sets a single cursor at the
  new node's immediate parent. `navigate/2` sets cursors for every parent-child
  pair along the path from root to the target, so the branch that was just
  navigated to is fully pinned. `extend/1` follows these cursors to walk from
  the current head to a leaf, reconstructing a full path after navigating to a
  mid-tree branch point.

  ## Enumerable

  Implements `Enumerable`, yielding tree nodes (maps with `:id`, `:parent_id`,
  `:message`, and `:usage` keys) along the active path in root-to-leaf order.
  `Enum.count/1` returns the active path length.
  """

  alias Omni.{Message, Usage}

  @typedoc "A tree of conversation messages with an active path cursor."
  @type t :: %__MODULE__{
          nodes: %{node_id() => tree_node()},
          path: [node_id()],
          cursors: %{node_id() => node_id()}
        }

  @typedoc "Integer node identifier, assigned sequentially."
  @type node_id :: non_neg_integer()

  @typedoc "A tree node wrapping a message with tree metadata."
  @type tree_node :: %{
          id: node_id(),
          parent_id: node_id() | nil,
          message: Message.t(),
          usage: Usage.t() | nil
        }

  defstruct nodes: %{}, path: [], cursors: %{}

  @doc """
  Creates a new tree from a keyword list or map.

  Accepts `:nodes` (list of tree nodes or a pre-built `node_id => node` map),
  `:path`, and `:cursors`. Primarily used for hydration from a persisted store.
  """
  @spec new(Enumerable.t()) :: t()
  def new(attrs) do
    attrs
    |> Map.new()
    |> Map.update(:nodes, %{}, fn
      nodes when is_map(nodes) -> nodes
      nodes when is_list(nodes) -> Map.new(nodes, &{&1.id, &1})
    end)
    |> then(&struct!(__MODULE__, &1))
  end

  # Query

  @doc "Returns a flat list of all messages along the active path, in order."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = tree) do
    Enum.map(tree, & &1.message)
  end

  @doc "Returns the total number of nodes in the tree."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{nodes: nodes}), do: map_size(nodes)

  @doc "Returns the cumulative usage across all nodes in the tree."
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{nodes: nodes}) do
    Enum.reduce(nodes, %Usage{}, fn {_id, node}, acc ->
      case node.usage do
        nil -> acc
        usage -> Usage.add(acc, usage)
      end
    end)
  end

  @doc "Returns the ID of the last node in the active path, or `nil` if empty."
  @spec head(t()) :: node_id() | nil
  def head(%__MODULE__{path: []}), do: nil
  def head(%__MODULE__{path: path}), do: List.last(path)

  @doc "Returns the full tree node for a given ID, or `nil` if not found."
  @spec get_node(t(), node_id()) :: tree_node() | nil
  def get_node(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc "Returns the message for a given ID, or `nil` if not found."
  @spec get_message(t(), node_id()) :: Message.t() | nil
  def get_message(%__MODULE__{nodes: nodes}, id), do: get_in(nodes, [id, :message])

  # Mutate

  @doc """
  Appends a message to the head of the active path. Pipe-safe.

  Also sets the cursor for the parent node to point at the new node, so that
  `extend/1` will follow this branch by default.
  """
  @spec push(t(), Message.t(), Usage.t() | nil) :: t()
  def push(%__MODULE__{} = tree, %Message{} = message, usage \\ nil) do
    {_id, tree} = push_node(tree, message, usage)
    tree
  end

  @doc """
  Like `push/3`, but returns `{node_id, tree}` for when you need the new node's ID.

  Sets the cursor for the parent node, same as `push/3`.
  """
  @spec push_node(t(), Message.t(), Usage.t() | nil) :: {node_id(), t()}
  def push_node(
        %__MODULE__{nodes: nodes, path: path, cursors: cursors} = tree,
        %Message{} = message,
        usage \\ nil
      ) do
    id = size(tree) + 1
    parent_id = head(tree)

    node = %{
      id: id,
      parent_id: parent_id,
      message: message,
      usage: usage
    }

    cursors = if parent_id, do: Map.put(cursors, parent_id, id), else: cursors
    {id, %{tree | nodes: Map.put(nodes, id, node), path: path ++ [id], cursors: cursors}}
  end

  @doc """
  Sets the active path by walking parent pointers from `node_id` back to root.

  Sets cursors for every parent-child pair along the navigated path, so
  `extend/1` from any ancestor reproduces this branch. This makes navigation
  fully pin the selected branch, overriding any cursors left by earlier pushes
  or navigations.

  Passing `nil` clears the active path without touching the node set or
  cursors. A subsequent `push/3` will create a new root (parent `nil`),
  allowing the tree to hold multiple disjoint roots.

  Returns `{:error, :not_found}` if the node ID doesn't exist in the tree.
  """
  @spec navigate(t(), node_id() | nil) :: {:ok, t()} | {:error, :not_found}
  def navigate(%__MODULE__{} = tree, nil), do: {:ok, %{tree | path: []}}

  def navigate(%__MODULE__{nodes: nodes} = tree, node_id) do
    case walk_to_root(nodes, node_id) do
      {:ok, path} ->
        cursors =
          path
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.reduce(tree.cursors, fn [parent, child], acc ->
            Map.put(acc, parent, child)
          end)

        {:ok, %{tree | path: path, cursors: cursors}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Extends the active path from head to a leaf node.

  At each level, follows the cursor if one exists for the current head,
  otherwise falls back to the last (most recent) child. Stops when
  reaching a node with no children.
  """
  @spec extend(t()) :: t()
  def extend(%__MODULE__{path: []} = tree), do: tree

  def extend(%__MODULE__{nodes: nodes, path: path, cursors: cursors} = tree) do
    %{tree | path: extend_path(nodes, cursors, path)}
  end

  # Introspect

  @doc "Returns the IDs of all nodes whose parent is the given node."
  @spec children(t(), node_id()) :: [node_id()]
  def children(%__MODULE__{nodes: nodes}, node_id), do: children_of(nodes, node_id)

  @doc "Returns other children of the same parent, excluding the given node."
  @spec siblings(t(), node_id()) :: [node_id()]
  def siblings(%__MODULE__{nodes: nodes} = tree, node_id) do
    case Map.get(nodes, node_id) do
      nil ->
        []

      %{parent_id: nil} ->
        roots(tree) -- [node_id]

      %{parent_id: parent_id} ->
        children(tree, parent_id) -- [node_id]
    end
  end

  @doc """
  Walks parent pointers from `node_id` to root, returns the path in root-first order.

  Useful for UIs that need to show the full path to a specific branch point.
  """
  @spec path_to(t(), node_id()) :: {:ok, [node_id()]} | {:error, :not_found}
  def path_to(%__MODULE__{nodes: nodes}, node_id), do: walk_to_root(nodes, node_id)

  @doc "Returns IDs of all nodes with `parent_id: nil`."
  @spec roots(t()) :: [node_id()]
  def roots(%__MODULE__{nodes: nodes}) do
    nodes
    |> Enum.filter(fn {_id, node} -> node.parent_id == nil end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Internal

  defp children_of(nodes, node_id) do
    nodes
    |> Enum.filter(fn {_id, node} -> node.parent_id == node_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp extend_path(nodes, cursors, path) do
    head = List.last(path)

    case children_of(nodes, head) do
      [] ->
        path

      children ->
        next = Map.get(cursors, head, List.last(children))
        extend_path(nodes, cursors, path ++ [next])
    end
  end

  defp walk_to_root(nodes, id, acc \\ [])

  defp walk_to_root(nodes, id, acc) do
    case Map.get(nodes, id) do
      nil -> {:error, :not_found}
      %{parent_id: nil} -> {:ok, [id | acc]}
      %{parent_id: parent_id} -> walk_to_root(nodes, parent_id, [id | acc])
    end
  end

  defimpl Enumerable do
    def reduce(tree, cmd, fun) do
      tree.path
      |> Enum.map(&tree.nodes[&1])
      |> Enumerable.List.reduce(cmd, fun)
    end

    def count(tree), do: {:ok, length(tree.path)}
    def member?(_tree, _element), do: {:error, __MODULE__}
    def slice(_tree), do: {:error, __MODULE__}
  end
end
