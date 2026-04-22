defmodule Omni.Session.StatusForwardingTest do
  use Omni.Session.SessionCase, async: false

  @moduletag :tmp_dir

  describe ":status forwarding" do
    test "forwards Agent :status events as {:session, _, :status, status}", ctx do
      {session, _} = start_session(ctx)

      :ok = Session.prompt(session, "Hello!")

      assert_receive {:session, ^session, :status, :running}, 1000
      assert_receive {:session, ^session, :status, :idle}, 2000
    end

    test "Session's cached agent_status tracks the last status", ctx do
      {session, _} = start_session(ctx)

      :ok = Session.prompt(session, "Hello!")
      events = collect_session_events(session)

      # After a complete turn the agent settles at :idle.
      assert :sys.get_state(session).agent_status == :idle

      # And we saw both transitions in the session stream.
      statuses = for {:status, s} <- events, do: s
      assert :running in statuses
      assert :idle in statuses
    end
  end
end
