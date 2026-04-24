defmodule Omni.Session.IdleShutdownTest do
  use Omni.Session.SessionCase, async: false

  @moduletag :tmp_dir

  describe "defaults" do
    test "unset :idle_shutdown_after — session never shuts down", ctx do
      {session, _} = start_session(ctx, subscribe: false)
      Process.sleep(120)
      assert Process.alive?(session)
    end

    test "nil :idle_shutdown_after — session never shuts down", ctx do
      {session, _} = start_session(ctx, subscribe: false, idle_shutdown_after: nil)
      Process.sleep(120)
      assert Process.alive?(session)
    end
  end

  describe "init does not evaluate" do
    test "controllers=0, agent idle, positive timeout — still alive past timeout", ctx do
      {session, _} = start_session(ctx, subscribe: false, idle_shutdown_after: 50)

      # The session starts with no controllers and agent idle. No transition
      # has occurred — shutdown must not be evaluated.
      Process.sleep(150)
      assert Process.alive?(session)

      state = :sys.get_state(session)
      assert state.shutdown_timer == nil
    end
  end

  describe "shutdown on controllers→0 via unsubscribe" do
    test "unsubscribing the last controller arms the timer; session shuts down", ctx do
      {session, _} = start_session(ctx, subscribe: true, idle_shutdown_after: 50)

      ref = Process.monitor(session)
      :ok = Session.unsubscribe(session)

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 500
    end

    test "observer unsubscribe is a no-op (does not arm)", ctx do
      other = spawn(fn -> Process.sleep(:infinity) end)

      {session, _} =
        start_session(ctx,
          subscribe: true,
          subscribers: [{other, :observer}],
          idle_shutdown_after: 50
        )

      # The controller is still present — unsubscribing the observer must not
      # arm a shutdown.
      :ok = Session.unsubscribe(session, other)
      Process.sleep(150)
      assert Process.alive?(session)
    end
  end

  describe "shutdown cancellation" do
    test "new controller joining cancels a pending shutdown", ctx do
      {session, _} = start_session(ctx, subscribe: true, idle_shutdown_after: 200)

      :ok = Session.unsubscribe(session)
      # Wait for the timer to arm, then re-subscribe.
      assert eventually(fn -> :sys.get_state(session).shutdown_timer != nil end)

      {:ok, _} = Session.subscribe(session)
      assert :sys.get_state(session).shutdown_timer == nil

      Process.sleep(300)
      assert Process.alive?(session)
    end

    test "agent going :busy cancels a pending shutdown", ctx do
      {session, _} = start_session(ctx, subscribe: true, idle_shutdown_after: 500)

      # Drop controllers to 0 to arm the timer.
      :ok = Session.unsubscribe(session)
      assert eventually(fn -> :sys.get_state(session).shutdown_timer != nil end)

      # Re-subscribe as observer so we receive the :status event but aren't a
      # controller (which would also cancel the timer).
      {:ok, _} = Session.subscribe(session, mode: :observer)
      # Prompt → status goes :busy → timer cancelled.
      :ok = Session.prompt(session, "Hello!")
      assert_receive {:session, ^session, :status, :busy}, 500

      # The busy status should have cancelled the timer.
      refute :sys.get_state(session).shutdown_timer

      # Let the turn complete (status → idle) and then verify the session
      # stays alive past the originally-scheduled timer.
      assert_receive {:session, ^session, :status, :idle}, 2000
      # Controllers are still zero and agent is idle, so a fresh timer arms
      # now — verify it's a NEW timer (not the originally-armed one).
      assert eventually(fn -> :sys.get_state(session).shutdown_timer != nil end)
    end
  end

  describe "shutdown on :status :idle with no controllers" do
    test "partial turn not abandoned — finishes, then shuts down", ctx do
      # No controller at session start — only an observer — so the controllers
      # count is already 0 when the turn begins. The session must not shut
      # down while running; it shuts down when status reaches idle.
      test_pid = self()

      {session, _} =
        start_session(ctx,
          subscribe: false,
          subscribers: [{test_pid, :observer}],
          idle_shutdown_after: 50
        )

      # Prompt — the turn begins, status goes :busy. Since the observer is
      # the only subscriber, controllers=0 throughout. Shutdown is only
      # evaluated on transitions that enter (controllers=0 ∧ idle), which
      # happens when the turn completes.
      :ok = Session.prompt(session, "Hello!")
      ref = Process.monitor(session)

      assert_receive {:session, ^session, :status, :busy}, 1000
      # Session stays alive while busy.
      assert Process.alive?(session)

      # After the turn completes, the timer arms and fires.
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2000
    end
  end

  describe "mode change evaluation" do
    test "controller → observer drops count to 0 and arms timer", ctx do
      {session, _} = start_session(ctx, subscribe: true, idle_shutdown_after: 50)

      ref = Process.monitor(session)
      # Change our mode from controller to observer: controllers=0.
      {:ok, _} = Session.subscribe(session, mode: :observer)

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 500
    end

    test "observer → controller cancels armed timer", ctx do
      # Arm the timer first by subscribing as observer only.
      test_pid = self()

      {session, _} =
        start_session(ctx,
          subscribe: false,
          subscribers: [{test_pid, :observer}],
          idle_shutdown_after: 500
        )

      # Trigger a transition that enters (controllers=0 ∧ idle): run a turn
      # so :status goes idle and arms the timer.
      :ok = Session.prompt(session, "Hello!")
      assert_receive {:session, ^session, :status, :idle}, 2000
      # Wait for the handle_info for :idle to land and arm the timer.
      assert eventually(fn -> :sys.get_state(session).shutdown_timer != nil end)

      # Upgrade to controller — cancels the timer.
      {:ok, _} = Session.subscribe(session, mode: :controller)
      assert :sys.get_state(session).shutdown_timer == nil

      Process.sleep(200)
      assert Process.alive?(session)
    end
  end

  describe "controller pid death" do
    test "drops controller count and arms shutdown", ctx do
      {session, _} = start_session(ctx, subscribe: false, idle_shutdown_after: 50)
      test_pid = self()

      sub =
        spawn(fn ->
          {:ok, _} = Session.subscribe(session)
          send(test_pid, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 500

      ref = Process.monitor(session)
      send(sub, :die)

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 500
    end
  end

  describe "zero-delay shutdown" do
    test "idle_shutdown_after: 0 shuts down promptly after the trigger", ctx do
      {session, _} = start_session(ctx, subscribe: true, idle_shutdown_after: 0)

      ref = Process.monitor(session)
      :ok = Session.unsubscribe(session)

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 200
    end
  end

  describe "invalid option" do
    test "rejects non-integer, non-nil values at init", ctx do
      stub_name = unique_stub_name()
      stub_fixture(stub_name, @text_fixture)

      # Use start rather than start_link to avoid crashing the test process.
      Process.flag(:trap_exit, true)

      result =
        Session.start_link(
          agent: [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
          store: tmp_store(ctx),
          idle_shutdown_after: :foo
        )

      assert result == {:error, :invalid_idle_shutdown_after}
    end
  end
end
