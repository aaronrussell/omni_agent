defmodule Omni.Session.ManagerTitleServiceTest do
  use Omni.Session.SessionCase, async: true

  alias Omni.Session.Manager

  @moduletag :tmp_dir

  defp unique_name do
    String.to_atom(
      "Elixir.Omni.Session.ManagerTitleServiceTest.M#{System.unique_integer([:positive])}"
    )
  end

  defp title_service_pid(manager) do
    Process.whereis(Module.concat(manager, "TitleService"))
  end

  defp start_manager(ctx, opts \\ []) do
    name = unique_name()
    store = tmp_store(ctx)
    manager_opts = [name: name, store: store] ++ opts

    start_supervised!({Manager, manager_opts})
    {:ok, _entries} = Manager.subscribe(name)

    {name, store}
  end

  defp create_session(manager, opts \\ []) do
    stub_name = unique_stub_name()
    fixture = Keyword.get(opts, :fixture, @text_fixture)

    case Keyword.get(opts, :fixtures) do
      nil -> stub_fixture(stub_name, fixture)
      fixtures -> stub_sequence(stub_name, fixtures)
    end

    agent_opts = [model: model(), opts: [api_key: "k", plug: {Req.Test, stub_name}]]
    create_opts = Keyword.merge([agent: agent_opts], Keyword.drop(opts, [:fixture, :fixtures]))

    {:ok, pid} = Manager.create(manager, create_opts)
    assert_receive {:manager, _, :opened, %{id: id, pid: ^pid}}

    # Manager.create goes through DynamicSupervisor, breaking the
    # $callers chain. Allow the session to access the Req.Test stub.
    Req.Test.allow(stub_name, self(), pid)

    # Flush the TitleService mailbox so it processes the :opened event
    # and subscribes to the session before we return.
    if ts = title_service_pid(manager), do: :sys.get_state(ts)

    {pid, id, stub_name}
  end

  # ── Heuristic mode ─────────────────────────────────────────────

  describe "heuristic title generation" do
    test "generates title on first turn for untitled session", ctx do
      {manager, _store} = start_manager(ctx)
      {pid, id, _stub} = create_session(manager)

      Session.prompt(pid, "Tell me about Elixir programming")
      _ = collect_session_events(pid)

      assert_receive {:manager, _, :title, %{id: ^id, title: title}}, 2000
      assert is_binary(title)
      assert String.length(title) > 0
    end

    test "skips sessions created with explicit title", ctx do
      {manager, _store} = start_manager(ctx)
      {pid, id, _stub} = create_session(manager, title: "Explicit")

      Session.prompt(pid, "hello")
      _ = collect_session_events(pid)

      refute_receive {:manager, _, :title, %{id: ^id}}, 500
    end
  end

  # ── Manual title interactions ──────────────────────────────────

  describe "manual title interactions" do
    test "untracks when title set manually", ctx do
      {manager, _store} = start_manager(ctx)
      {pid, id, stub_name} = create_session(manager)

      Session.set_title(pid, "Manual")
      assert_receive {:manager, _, :title, %{id: ^id, title: "Manual"}}

      stub_fixture(stub_name, @text_fixture)
      Session.prompt(pid, "hello")
      _ = collect_session_events(pid)

      refute_receive {:manager, _, :title, %{id: ^id}}, 500
    end

    test "re-tracks when title cleared to nil", ctx do
      {manager, _store} = start_manager(ctx)
      {pid, id, stub_name} = create_session(manager, title: "Temp")

      Session.set_title(pid, nil)
      assert_receive {:manager, _, :title, %{id: ^id, title: nil}}

      stub_fixture(stub_name, @text_fixture)
      Session.prompt(pid, "Tell me about OTP")
      _ = collect_session_events(pid)

      assert_receive {:manager, _, :title, %{id: ^id, title: title}}, 2000
      assert is_binary(title)
    end
  end

  # ── Cleanup ────────────────────────────────────────────────────

  describe "cleanup" do
    test "cleans up on session close without crash", ctx do
      {manager, _store} = start_manager(ctx)
      {_pid, id, _stub} = create_session(manager)

      :ok = Manager.close(manager, id)
      assert_receive {:manager, _, :closed, %{id: ^id}}

      ts_pid = title_service_pid(manager)
      assert Process.alive?(ts_pid)
    end
  end

  # ── Disabled ───────────────────────────────────────────────────

  describe "title_generator: false" do
    test "does not start TitleService", ctx do
      {manager, _store} = start_manager(ctx, title_generator: false)
      assert title_service_pid(manager) == nil
    end
  end

  # ── LLM mode ───────────────────────────────────────────────────

  describe "LLM title generation" do
    test "generates title using configured model", ctx do
      title_stub = unique_stub_name()
      stub_fixture(title_stub, @text_fixture)

      {manager, _store} =
        start_manager(ctx,
          title_generator:
            {{:anthropic, "claude-haiku-4-5"}, api_key: "k", plug: {Req.Test, title_stub}}
        )

      ts = title_service_pid(manager)
      Req.Test.allow(title_stub, self(), ts)

      {pid, id, _stub} = create_session(manager)

      Session.prompt(pid, "Tell me about Elixir")
      _ = collect_session_events(pid)

      assert_receive {:manager, _, :title, %{id: ^id, title: title}}, 2000
      assert is_binary(title)
      assert String.length(title) > 0
    end
  end

  # ── Failure retry ──────────────────────────────────────────────

  describe "generation failure" do
    @tag capture_log: true
    test "retries on next turn after failure", ctx do
      title_stub = unique_stub_name()

      Req.Test.stub(title_stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "server error"}))
      end)

      {manager, _store} =
        start_manager(ctx,
          title_generator:
            {{:anthropic, "claude-haiku-4-5"}, api_key: "k", plug: {Req.Test, title_stub}}
        )

      ts = title_service_pid(manager)
      Req.Test.allow(title_stub, self(), ts)

      {pid, id, stub_name} = create_session(manager)

      Session.prompt(pid, "first turn")
      _ = collect_session_events(pid)

      refute_receive {:manager, _, :title, %{id: ^id}}, 500

      Req.Test.stub(title_stub, fn conn ->
        body = File.read!("test/support/fixtures/sse/anthropic_text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      stub_fixture(stub_name, @text_fixture)
      Session.prompt(pid, "second turn")
      _ = collect_session_events(pid)

      assert_receive {:manager, _, :title, %{id: ^id, title: title}}, 2000
      assert is_binary(title)
    end
  end
end
