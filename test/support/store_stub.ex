defmodule Omni.Agent.Store.Stub do
  @moduledoc false
  # Test-only store adapter. Reports each call to a caller-supplied
  # `:probe` pid and optionally returns injected errors per-operation
  # via an `:errors` map (keys: `:save_tree`, `:save_state`).
  #
  # Always returns `{:error, :not_found}` from `load/2` — tests that
  # need a real round-trip use `Omni.Agent.Store.FileSystem` instead.
  @behaviour Omni.Agent.Store

  @impl true
  def save_tree(id, tree, opts) do
    report(opts, {:save_tree, id, tree, opts})
    inject_error(opts, :save_tree)
  end

  @impl true
  def save_state(id, state_data, opts) do
    report(opts, {:save_state, id, state_data, opts})
    inject_error(opts, :save_state)
  end

  @impl true
  def load(id, opts) do
    report(opts, {:load, id, opts})
    {:error, :not_found}
  end

  @impl true
  def list(opts) do
    report(opts, {:list, opts})
    {:ok, []}
  end

  @impl true
  def delete(id, opts) do
    report(opts, {:delete, id, opts})
    :ok
  end

  defp report(opts, msg) do
    case Keyword.get(opts, :probe) do
      nil -> :ok
      pid when is_pid(pid) -> send(pid, msg)
    end
  end

  defp inject_error(opts, op) do
    case Keyword.get(opts, :errors, %{}) do
      %{^op => reason} -> {:error, reason}
      _ -> :ok
    end
  end
end
