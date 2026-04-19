defmodule Omni.Session.PubsubTest do
  use Omni.Session.SessionCase, async: true

  @moduletag :tmp_dir

  describe "subscribe/1,2" do
    test "returns a snapshot of the session and agent", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, snapshot} = Session.subscribe(session)

      assert %Snapshot{
               id: id,
               title: nil,
               tree: %Tree{},
               agent: %Omni.Agent.Snapshot{state: %Omni.Agent.State{}}
             } = snapshot

      assert is_binary(id)
    end

    test "delivers subsequent events to the subscriber", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "Hello")
      assert_receive {:session, ^session, :turn, {:stop, _}}, 2000
    end

    test "multiple subscribers receive identical event streams", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      test_pid = self()
      collectors = for _ <- 1..3, do: spawn_collector(test_pid, session)

      # Subscribe each collector
      for collector <- collectors do
        send(collector, :subscribe)
        assert_receive {^collector, :subscribed}, 1000
      end

      :ok = Session.prompt(session, "Hello")

      # Wait a beat for the turn to complete.
      Process.sleep(500)

      # Tell each collector to dump its event types.
      for collector <- collectors, do: send(collector, :dump)

      streams =
        for collector <- collectors do
          assert_receive {^collector, :events, events}, 1000
          Enum.map(events, &elem(&1, 0))
        end

      # All three streams carry the same event types in the same order.
      [first | rest] = streams
      Enum.each(rest, &assert(&1 == first))
    end

    test "start-time :subscribers registers the given pids", ctx do
      other = self()
      {session, _} = start_session(ctx, subscribe: false, subscribers: [other])

      :ok = Session.prompt(session, "Hello")
      assert_receive {:session, ^session, :turn, {:stop, _}}, 2000
    end
  end

  describe "unsubscribe/1,2" do
    test "removes the subscriber; no further events delivered", ctx do
      {session, _} = start_session(ctx)
      :ok = Session.unsubscribe(session)

      :ok = Session.prompt(session, "Hello")
      Process.sleep(300)

      refute_received {:session, ^session, _type, _data}
    end
  end

  describe "automatic cleanup" do
    test "subscriber exit removes it from the subscriber set", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      test_pid = self()

      collector =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session)
          send(test_pid, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 1000
      assert MapSet.member?(:sys.get_state(session).subscribers, collector)

      send(collector, :die)
      Process.sleep(100)

      refute MapSet.member?(:sys.get_state(session).subscribers, collector)
    end
  end

  describe "get_snapshot/1" do
    test "returns the session + agent snapshot at call time", ctx do
      {session, _} = start_session(ctx)

      snapshot = Session.get_snapshot(session)
      assert %Snapshot{} = snapshot
      assert snapshot.id == :sys.get_state(session).id
    end
  end

  defp spawn_collector(test_pid, session) do
    spawn(fn ->
      receive do
        :subscribe ->
          {:ok, _} = Session.subscribe(session)
          send(test_pid, {self(), :subscribed})
      end

      collect_loop([], test_pid)
    end)
  end

  defp collect_loop(acc, test_pid) do
    receive do
      :dump ->
        send(test_pid, {self(), :events, Enum.reverse(acc)})

      {:session, _, type, data} ->
        collect_loop([{type, data} | acc], test_pid)
    end
  end
end
