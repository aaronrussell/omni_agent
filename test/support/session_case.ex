defmodule Omni.Session.SessionCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Omni.Session
      alias Omni.Session.{Snapshot, Store, Tree}
      alias Omni.Session.Store.FileSystem
      alias Omni.{Context, Message, Response, Usage}
      alias Omni.Content.{Text, ToolResult, ToolUse}

      alias Omni.Agent.TestAgents.{ContinueAgent, WithInit, CustomTurn}

      @text_fixture "test/support/fixtures/sse/anthropic_text.sse"
      @tool_use_fixture "test/support/fixtures/sse/anthropic_tool_use.sse"
      @thinking_fixture "test/support/fixtures/sse/anthropic_thinking.sse"

      defp stub_fixture(stub_name, fixture_path) do
        Req.Test.stub(stub_name, fn conn ->
          body = File.read!(fixture_path)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
        end)
      end

      defp stub_sequence(stub_name, fixtures) do
        {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

        Req.Test.stub(stub_name, fn conn ->
          call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          fixture = Enum.at(fixtures, call_num, List.last(fixtures))
          body = File.read!(fixture)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
        end)
      end

      defp model do
        {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
        model
      end

      # Fresh per-test filesystem store. Uses ExUnit's @moduletag :tmp_dir.
      defp tmp_store(%{tmp_dir: dir}), do: {FileSystem, base_path: dir}
      defp tmp_store(_), do: raise("session_case tests require @moduletag :tmp_dir")

      defp unique_stub_name do
        :"session_test_#{System.unique_integer([:positive])}"
      end

      # Start a session wired up against a fixture-stubbed HTTP endpoint.
      # Returns `{session_pid, stub_name}`.
      defp start_session(ctx, opts \\ []) do
        stub_name = opts[:stub_name] || unique_stub_name()

        case opts[:fixtures] do
          nil -> stub_fixture(stub_name, opts[:fixture] || @text_fixture)
          fixtures -> stub_sequence(stub_name, fixtures)
        end

        {agent_mod_opts, opts} = Keyword.pop(opts, :agent_opts, [])
        {agent_mod, opts} = Keyword.pop(opts, :agent_module, nil)

        agent_opts =
          Keyword.merge(
            [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
            agent_mod_opts
          )

        agent = if agent_mod, do: {agent_mod, agent_opts}, else: agent_opts

        session_opts =
          [agent: agent, store: opts[:store] || tmp_store(ctx)]
          |> Keyword.merge(Keyword.drop(opts, [:stub_name, :fixture, :fixtures, :store]))
          |> with_default_subscribe()

        {:ok, session} = Session.start_link(session_opts)
        {session, stub_name}
      end

      defp with_default_subscribe(opts) do
        if Keyword.has_key?(opts, :subscribe) or Keyword.has_key?(opts, :subscribers) do
          opts
        else
          Keyword.put(opts, :subscribe, true)
        end
      end

      # Collects `{:session, pid, type, data}` events for up to `timeout`
      # ms, or until the turn terminates — `:turn {:stop, _}`, `:error`,
      # or `:cancelled` — plus a short flush window so trailing
      # `:tree` / `:store` events are included.
      defp collect_session_events(session_pid, timeout \\ 2000) do
        collect_session_events_loop(session_pid, [], timeout, false)
      end

      defp collect_session_events_loop(session_pid, acc, timeout, flushing?) do
        wait = if flushing?, do: 200, else: timeout

        receive do
          {:session, ^session_pid, :turn, {:stop, _} = data} ->
            collect_session_events_loop(session_pid, [{:turn, data} | acc], timeout, true)

          {:session, ^session_pid, :error, reason} ->
            collect_session_events_loop(session_pid, [{:error, reason} | acc], timeout, true)

          {:session, ^session_pid, :cancelled, data} ->
            collect_session_events_loop(session_pid, [{:cancelled, data} | acc], timeout, true)

          {:session, ^session_pid, type, data} ->
            collect_session_events_loop(session_pid, [{type, data} | acc], timeout, flushing?)
        after
          wait -> Enum.reverse(acc)
        end
      end
    end
  end
end
