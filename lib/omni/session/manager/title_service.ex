defmodule Omni.Session.Manager.TitleService do
  @moduledoc false

  # Auto-generates titles for untitled sessions under an
  # `Omni.Session.Manager`.
  #
  # Subscribes to the Manager and watches for sessions opened without a
  # title. For each such session it observes the agent stream and, once
  # a turn commits, calls `Omni.Session.Title.generate/3` in an async
  # task and writes the result back via `Omni.Session.set_title/2`.
  #
  # Started conditionally by the Manager supervisor when
  # `title_generator` is not `false`.

  use GenServer
  require Logger

  alias Omni.Session
  alias Omni.Session.Manager
  alias Omni.Session.Title

  defstruct manager: nil,
            title_generator: :heuristic,
            title_opts: [],
            pending: %{},
            task_refs: %{},
            session_refs: %{}

  # ── Lifecycle ──────────────────────────────────────────────────

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    manager = Keyword.fetch!(opts, :manager)
    title_generator = Keyword.fetch!(opts, :title_generator)
    title_opts = Keyword.get(opts, :title_opts, [])

    state = %__MODULE__{
      manager: manager,
      title_generator: title_generator,
      title_opts: title_opts
    }

    case Manager.subscribe(manager) do
      {:ok, entries} ->
        state =
          Enum.reduce(entries, state, fn entry, acc ->
            if is_nil(entry.title), do: track(acc, entry.id, entry.pid), else: acc
          end)

        {:ok, state}
    end
  end

  # ── Manager events ─────────────────────────────────────────────

  @impl true
  def handle_info({:manager, _mod, :opened, %{id: id, title: nil, pid: pid}}, state) do
    state = if Map.has_key?(state.pending, id), do: state, else: track(state, id, pid)
    {:noreply, state}
  end

  def handle_info({:manager, _mod, :opened, _entry}, state), do: {:noreply, state}

  def handle_info({:manager, _mod, :title, %{id: id, title: nil}}, state) do
    state =
      if Map.has_key?(state.pending, id) do
        state
      else
        case Manager.whereis(state.manager, id) do
          nil -> state
          pid -> track(state, id, pid)
        end
      end

    {:noreply, state}
  end

  def handle_info({:manager, _mod, :title, %{id: id}}, state) do
    {:noreply, untrack(state, id)}
  end

  def handle_info({:manager, _mod, :closed, %{id: id}}, state) do
    {:noreply, untrack(state, id)}
  end

  def handle_info({:manager, _mod, :status, _}, state), do: {:noreply, state}

  # ── Session events ─────────────────────────────────────────────

  def handle_info({:session, pid, :turn, {:stop, _response}}, state) do
    case find_by_pid(state, pid) do
      nil -> {:noreply, state}
      {id, %{task: nil}} -> {:noreply, start_generation(state, id, pid)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:session, _pid, _type, _data}, state), do: {:noreply, state}

  # ── Task results ───────────────────────────────────────────────

  def handle_info({ref, {:ok, title}}, state) when is_reference(ref) do
    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, task_refs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | task_refs: task_refs}

        case Map.get(state.pending, id) do
          nil ->
            {:noreply, state}

          %{pid: pid} ->
            try do
              Session.set_title(pid, title)
            catch
              :exit, _ -> :ok
            end

            {:noreply, untrack(state, id)}
        end
    end
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    case Map.pop(state.task_refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {id, task_refs} ->
        Process.demonitor(ref, [:flush])

        Logger.warning(
          "#{inspect(__MODULE__)}: title generation failed for #{id}: #{inspect(reason)}"
        )

        state = %{state | task_refs: task_refs}
        {:noreply, clear_task(state, id)}
    end
  end

  # ── Monitors ───────────────────────────────────────────────────

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.task_refs, ref) ->
        {id, task_refs} = Map.pop(state.task_refs, ref)
        Logger.warning("#{inspect(__MODULE__)}: title task crashed for #{id}: #{inspect(reason)}")
        state = %{state | task_refs: task_refs}
        {:noreply, clear_task(state, id)}

      Map.has_key?(state.session_refs, ref) ->
        {id, session_refs} = Map.pop(state.session_refs, ref)
        state = %{state | session_refs: session_refs}
        {:noreply, drop_pending(state, id)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals: tracking ────────────────────────────────────────

  defp track(state, id, pid) do
    case safe_subscribe(pid) do
      :ok ->
        ref = Process.monitor(pid)
        entry = %{pid: pid, monitor: ref, task: nil}

        %{
          state
          | pending: Map.put(state.pending, id, entry),
            session_refs: Map.put(state.session_refs, ref, id)
        }

      :error ->
        state
    end
  end

  defp untrack(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {entry, pending} ->
        if entry.task, do: Task.shutdown(entry.task, :brutal_kill)

        task_refs =
          if entry.task,
            do: Map.delete(state.task_refs, entry.task.ref),
            else: state.task_refs

        Process.demonitor(entry.monitor, [:flush])

        try do
          Session.unsubscribe(entry.pid)
        catch
          :exit, _ -> :ok
        end

        %{
          state
          | pending: pending,
            task_refs: task_refs,
            session_refs: Map.delete(state.session_refs, entry.monitor)
        }
    end
  end

  defp drop_pending(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {entry, pending} ->
        if entry.task, do: Task.shutdown(entry.task, :brutal_kill)

        task_refs =
          if entry.task,
            do: Map.delete(state.task_refs, entry.task.ref),
            else: state.task_refs

        %{state | pending: pending, task_refs: task_refs}
    end
  end

  defp clear_task(state, id) do
    case Map.fetch(state.pending, id) do
      :error ->
        state

      {:ok, entry} ->
        %{state | pending: Map.put(state.pending, id, %{entry | task: nil})}
    end
  end

  # ── Internals: generation ──────────────────────────────────────

  defp start_generation(state, id, pid) do
    try do
      snapshot = Session.get_snapshot(pid)
      messages = Omni.Session.Tree.messages(snapshot.tree)
      title_generator = state.title_generator
      title_opts = state.title_opts

      task = Task.async(fn -> Title.generate(title_generator, messages, title_opts) end)

      entry = Map.fetch!(state.pending, id)

      %{
        state
        | pending: Map.put(state.pending, id, %{entry | task: task}),
          task_refs: Map.put(state.task_refs, task.ref, id)
      }
    catch
      :exit, _ ->
        state
    end
  end

  defp find_by_pid(state, pid) do
    Enum.find(state.pending, fn {_id, entry} -> entry.pid == pid end)
  end

  defp safe_subscribe(pid) do
    case Session.subscribe(pid, self(), mode: :observer) do
      {:ok, _snapshot} -> :ok
    end
  catch
    :exit, _ -> :error
  end
end
