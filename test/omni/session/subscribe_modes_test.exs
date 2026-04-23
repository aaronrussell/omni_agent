defmodule Omni.Session.SubscribeModesTest do
  use Omni.Session.SessionCase, async: false

  @moduletag :tmp_dir

  describe "subscribe/1,2 default mode" do
    test "subscribe/1 registers caller as :controller", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _snap} = Session.subscribe(session)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, self())
      assert MapSet.member?(state.controllers, self())
    end

    test "subscribe(session, pid) (bare-pid) registers as :controller", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      other = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, _snap} = Session.subscribe(session, other)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, other)
      assert MapSet.member?(state.controllers, other)
    end
  end

  describe "subscribe/2,3 with :mode option" do
    test "mode: :observer registers in subscribers but NOT controllers", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _snap} = Session.subscribe(session, mode: :observer)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, self())
      refute MapSet.member?(state.controllers, self())
    end

    test "subscribe/3 pid + opts", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      other = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, _snap} = Session.subscribe(session, other, mode: :observer)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, other)
      refute MapSet.member?(state.controllers, other)
    end
  end

  describe "idempotency and mode change" do
    test "second subscribe with same mode is a no-op", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _} = Session.subscribe(session)
      {:ok, _} = Session.subscribe(session)

      state = :sys.get_state(session)
      assert MapSet.size(state.controllers) == 1
      # Exactly one monitor ref for this pid.
      assert Enum.count(state.monitors, fn {_ref, pid} -> pid == self() end) == 1
    end

    test "second subscribe with different mode updates mode in place", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _} = Session.subscribe(session, mode: :controller)
      {:ok, _} = Session.subscribe(session, mode: :observer)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, self())
      refute MapSet.member?(state.controllers, self())
      # Still one monitor.
      assert Enum.count(state.monitors, fn {_ref, pid} -> pid == self() end) == 1
    end

    test "observer → controller also updates mode in place", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _} = Session.subscribe(session, mode: :observer)
      {:ok, _} = Session.subscribe(session, mode: :controller)

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, self())
      assert MapSet.member?(state.controllers, self())
    end
  end

  describe "unsubscribe" do
    test "releases a controller", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _} = Session.subscribe(session)
      :ok = Session.unsubscribe(session)

      state = :sys.get_state(session)
      refute MapSet.member?(state.subscribers, self())
      refute MapSet.member?(state.controllers, self())
    end

    test "releases an observer", ctx do
      {session, _} = start_session(ctx, subscribe: false)

      {:ok, _} = Session.subscribe(session, mode: :observer)
      :ok = Session.unsubscribe(session)

      state = :sys.get_state(session)
      refute MapSet.member?(state.subscribers, self())
    end
  end

  describe "monitor cleanup on subscriber death" do
    test "controller pid death removes from subscribers and controllers", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      test_pid = self()

      pid =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session)
          send(test_pid, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 500
      assert MapSet.member?(:sys.get_state(session).controllers, pid)

      send(pid, :die)

      assert eventually(fn ->
               state = :sys.get_state(session)

               not MapSet.member?(state.subscribers, pid) and
                 not MapSet.member?(state.controllers, pid)
             end)
    end

    test "observer pid death removes from subscribers", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      test_pid = self()

      pid =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session, mode: :observer)
          send(test_pid, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 500
      assert MapSet.member?(:sys.get_state(session).subscribers, pid)

      send(pid, :die)

      assert eventually(fn ->
               not MapSet.member?(:sys.get_state(session).subscribers, pid)
             end)
    end
  end

  describe "start-opt :subscribers shape" do
    test "bare pid defaults to :controller", ctx do
      other = spawn(fn -> Process.sleep(:infinity) end)

      {session, _} = start_session(ctx, subscribe: false, subscribers: [other])

      state = :sys.get_state(session)
      assert MapSet.member?(state.controllers, other)
    end

    test "{pid, :observer} tuple registers as observer", ctx do
      other = spawn(fn -> Process.sleep(:infinity) end)

      {session, _} = start_session(ctx, subscribe: false, subscribers: [{other, :observer}])

      state = :sys.get_state(session)
      assert MapSet.member?(state.subscribers, other)
      refute MapSet.member?(state.controllers, other)
    end

    test "mixed shape handled per-entry", ctx do
      a = spawn(fn -> Process.sleep(:infinity) end)
      b = spawn(fn -> Process.sleep(:infinity) end)

      {session, _} = start_session(ctx, subscribe: false, subscribers: [a, {b, :observer}])

      state = :sys.get_state(session)
      assert MapSet.member?(state.controllers, a)
      assert MapSet.member?(state.subscribers, b)
      refute MapSet.member?(state.controllers, b)
    end

    test "subscribe: true registers caller as controller", ctx do
      {session, _} = start_session(ctx, subscribe: true)

      state = :sys.get_state(session)
      assert MapSet.member?(state.controllers, self())
    end
  end

  describe "both modes receive events" do
    test "controllers and observers both receive forwarded events", ctx do
      test_pid = self()

      observer_pid =
        spawn(fn ->
          receive do
            {:session, _, :title, title} -> send(test_pid, {:observer_got, title})
          after
            2000 -> send(test_pid, :observer_timeout)
          end
        end)

      {session, _} =
        start_session(ctx,
          subscribe: true,
          subscribers: [{observer_pid, :observer}]
        )

      :ok = Session.set_title(session, "Hello")

      assert_receive {:session, ^session, :title, "Hello"}, 500
      assert_receive {:observer_got, "Hello"}, 500
    end
  end
end
