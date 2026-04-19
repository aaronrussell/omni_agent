defmodule Omni.Session.Store.Failing do
  @moduledoc false

  # Store adapter that can be configured to fail selected operations.
  # Useful for verifying Session's :store {:error, _, _} event path.
  #
  # Options:
  #   :fail_save_tree  — reason atom to return from save_tree, or nil
  #   :fail_save_state — reason atom to return from save_state, or nil
  #   :fail_load       — set to :not_found to simulate a missing session
  #   :delegate        — optional inner store to dispatch to when ops
  #                       aren't configured to fail
  #
  # When :delegate is absent, non-failing ops return :ok with empty data.

  @behaviour Omni.Session.Store

  alias Omni.Session.Tree

  @impl true
  def save_tree(cfg, id, tree, opts) do
    case Keyword.get(cfg, :fail_save_tree) do
      nil ->
        case Keyword.get(cfg, :delegate) do
          nil -> :ok
          store -> Omni.Session.Store.save_tree(store, id, tree, opts)
        end

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def save_state(cfg, id, state, opts) do
    case Keyword.get(cfg, :fail_save_state) do
      nil ->
        case Keyword.get(cfg, :delegate) do
          nil -> :ok
          store -> Omni.Session.Store.save_state(store, id, state, opts)
        end

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def load(cfg, id, opts) do
    case Keyword.get(cfg, :fail_load) do
      :not_found ->
        {:error, :not_found}

      nil ->
        case Keyword.get(cfg, :delegate) do
          nil -> {:ok, %Tree{}, %{}}
          store -> Omni.Session.Store.load(store, id, opts)
        end
    end
  end

  @impl true
  def list(cfg, opts) do
    case Keyword.get(cfg, :delegate) do
      nil -> {:ok, []}
      store -> Omni.Session.Store.list(store, opts)
    end
  end

  @impl true
  def delete(cfg, id, opts) do
    case Keyword.get(cfg, :delegate) do
      nil -> :ok
      store -> Omni.Session.Store.delete(store, id, opts)
    end
  end
end
