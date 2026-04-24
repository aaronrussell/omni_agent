defmodule Omni.Session.Manager.Tracker do
  @moduledoc false

  # In-memory projection of every session currently running under an
  # `Omni.Session.Manager`. Subscribes to each session as `:observer`
  # (so it does not pin the session's lifetime) and maintains a
  # `%{id => %{id, title, status, pid}}` map. Fans out
  # `:opened` / `:status` / `:title` / `:closed` events to
  # Manager-level subscribers.
  #
  # Internal to the Manager. Callers go through
  # `Omni.Session.Manager.list_open/1` and
  # `Omni.Session.Manager.subscribe/1` rather than calling this module
  # directly.

  use GenServer

  alias Omni.Session

  defstruct [
    :manager,
    :registry,
    sessions: %{},
    pid_to_id: %{},
    subscribers: MapSet.new(),
    monitors: %{}
  ]

  # ── Public API ─────────────────────────────────────────────────────

  # Only `add/3` has a dedicated wrapper — it's a Manager-internal
  # hand-off with no equivalent on the Manager public API, and the name
  # carries intent worth keeping at the call site. Everything else
  # (list_open, subscribe, unsubscribe) is a 1:1 mirror of Manager's
  # public API; Manager invokes those via `GenServer.call` directly.

  def start_link(opts) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gs_opts)
  end

  def add(tracker, id, pid) when is_binary(id) and is_pid(pid) do
    GenServer.call(tracker, {:add, id, pid})
  end

  # ── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    manager = Keyword.fetch!(opts, :manager)
    registry = Keyword.fetch!(opts, :registry)

    state = %__MODULE__{manager: manager, registry: registry}
    {:ok, state, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state) do
    # On a normal (fresh) start the registry is empty and this is a
    # no-op. On a Tracker restart under the Manager supervisor, the
    # sessions the previous Tracker was watching are still running and
    # registered — re-observe them silently (no :opened fires,
    # since Manager-level subscribers died with the previous Tracker).
    entries =
      try do
        Registry.select(state.registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      rescue
        ArgumentError -> []
      end

    state = Enum.reduce(entries, state, fn {id, pid}, acc -> track_new(acc, id, pid, false) end)
    {:noreply, state}
  end

  @impl true
  def handle_call({:add, id, pid}, _from, state) do
    if Map.has_key?(state.sessions, id) do
      {:reply, :ok, state}
    else
      {:reply, :ok, track_new(state, id, pid, true)}
    end
  end

  def handle_call(:list_open, _from, state) do
    {:reply, Map.values(state.sessions), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if MapSet.member?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)

        %{
          state
          | subscribers: MapSet.put(state.subscribers, pid),
            monitors: Map.put(state.monitors, ref, {:subscriber, pid})
        }
      end

    {:reply, {:ok, Map.values(state.sessions)}, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  @impl true
  def handle_info({:session, session_pid, :status, status}, state) do
    case Map.get(state.pid_to_id, session_pid) do
      nil ->
        {:noreply, state}

      id ->
        state = update_entry(state, id, fn entry -> %{entry | status: status} end)
        broadcast(state, :status, %{id: id, status: status})
        {:noreply, state}
    end
  end

  def handle_info({:session, session_pid, :title, title}, state) do
    case Map.get(state.pid_to_id, session_pid) do
      nil ->
        {:noreply, state}

      id ->
        state = update_entry(state, id, fn entry -> %{entry | title: title} end)
        broadcast(state, :title, %{id: id, title: title})
        {:noreply, state}
    end
  end

  def handle_info({:session, _pid, _type, _payload}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{:session, id}, monitors} ->
        state = drop_session(%{state | monitors: monitors}, id)
        {:noreply, state}

      {{:subscriber, pid}, monitors} ->
        state = %{
          state
          | monitors: monitors,
            subscribers: MapSet.delete(state.subscribers, pid)
        }

        {:noreply, state}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ────────────────────────────────────────────────────────

  # Monitor + observer-subscribe a new session. Returns state unchanged
  # if the session has already died (monitor delivered DOWN or subscribe
  # exited noproc). On success inserts an entry and — when `emit?` is
  # true — broadcasts `:opened`.
  defp track_new(state, id, pid, emit?) do
    ref = Process.monitor(pid)

    case safe_subscribe(pid) do
      {:ok, snapshot} ->
        entry = %{
          id: id,
          title: snapshot.title,
          status: snapshot.agent.state.status,
          pid: pid
        }

        state = %{
          state
          | sessions: Map.put(state.sessions, id, entry),
            pid_to_id: Map.put(state.pid_to_id, pid, id),
            monitors: Map.put(state.monitors, ref, {:session, id})
        }

        if emit?, do: broadcast(state, :opened, entry)
        state

      :error ->
        Process.demonitor(ref, [:flush])
        state
    end
  end

  defp safe_subscribe(pid) do
    Session.subscribe(pid, self(), mode: :observer)
  catch
    :exit, _ -> :error
  end

  defp drop_session(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _} ->
        state

      {%{pid: pid}, sessions} ->
        state = %{
          state
          | sessions: sessions,
            pid_to_id: Map.delete(state.pid_to_id, pid)
        }

        broadcast(state, :closed, %{id: id})
        state
    end
  end

  defp drop_subscriber(state, pid) do
    case find_monitor_ref(state.monitors, {:subscriber, pid}) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | subscribers: MapSet.delete(state.subscribers, pid),
            monitors: Map.delete(state.monitors, ref)
        }
    end
  end

  defp find_monitor_ref(monitors, tag) do
    Enum.find_value(monitors, fn {ref, t} -> t == tag && ref end)
  end

  defp update_entry(state, id, fun) do
    case Map.fetch(state.sessions, id) do
      {:ok, entry} -> %{state | sessions: Map.put(state.sessions, id, fun.(entry))}
      :error -> state
    end
  end

  defp broadcast(state, event, payload) do
    msg = {:manager, state.manager, event, payload}
    Enum.each(state.subscribers, &send(&1, msg))
    :ok
  end
end
