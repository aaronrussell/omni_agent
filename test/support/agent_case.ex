defmodule Omni.Agent.AgentCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Omni.Agent
      alias Omni.{Context, Response}
      alias Omni.Content.{Text, ToolResult, ToolUse}

      alias Omni.Agent.TestAgents.{
        WithInit,
        FailInit,
        CustomTurn,
        RejectTool,
        ModifyResult,
        TrackToolUses,
        ContinueAgent,
        ErrorRetryAgent,
        TerminateAgent,
        CrashRetryAgent,
        PauseAgent,
        ResultAgent
      }

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

      defp stub_error(stub_name) do
        Req.Test.stub(stub_name, fn conn ->
          Plug.Conn.send_resp(conn, 500, "Internal Server Error")
        end)
      end

      defp stub_error_then_success(stub_name, fixture_path) do
        {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

        Req.Test.stub(stub_name, fn conn ->
          call_num = Elixir.Agent.get_and_update(counter, fn n -> {n, n + 1} end)

          if call_num == 0 do
            Plug.Conn.send_resp(conn, 500, "Internal Server Error")
          else
            body = File.read!(fixture_path)

            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, body)
          end
        end)
      end

      defp stub_slow(stub_name, fixture_path, delay \\ 2000) do
        Req.Test.stub(stub_name, fn conn ->
          Process.sleep(delay)
          body = File.read!(fixture_path)

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
        end)
      end

      defp tool_with_handler do
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}},
          handler: fn _input -> "72F and sunny" end
        )
      end

      defp tool_without_handler do
        Omni.tool(
          name: "get_weather",
          description: "Gets the weather",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}}
        )
      end

      defp model do
        {:ok, model} = Omni.get_model(:anthropic, "claude-haiku-4-5")
        model
      end

      defp start_agent(opts \\ []) do
        stub_name = opts[:stub_name] || unique_stub_name()

        case opts[:fixtures] do
          nil -> stub_fixture(stub_name, opts[:fixture] || @text_fixture)
          fixtures -> stub_sequence(stub_name, fixtures)
        end

        agent_opts =
          Keyword.merge(
            [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
            Keyword.drop(opts, [:stub_name, :fixture, :fixtures])
          )

        Agent.start_link(agent_opts)
      end

      defp start_agent_with_module(module, opts) do
        stub_name = opts[:stub_name] || unique_stub_name()

        case opts[:fixtures] do
          nil -> stub_fixture(stub_name, opts[:fixture] || @text_fixture)
          fixtures -> stub_sequence(stub_name, fixtures)
        end

        module_opts =
          Keyword.merge(
            [model: model(), opts: [api_key: "test-key", plug: {Req.Test, stub_name}]],
            Keyword.drop(opts, [:stub_name, :fixture, :fixtures])
          )

        module.start_link(module_opts)
      end

      defp unique_stub_name do
        :"agent_test_#{System.unique_integer([:positive])}"
      end

      defp collect_events(agent_pid, timeout \\ 5000) do
        collect_events_loop(agent_pid, [], timeout)
      end

      defp collect_events_loop(agent_pid, acc, timeout) do
        receive do
          {:agent, ^agent_pid, :continue, data} ->
            collect_events_loop(agent_pid, [{:continue, data} | acc], timeout)

          {:agent, ^agent_pid, :stop, data} ->
            Enum.reverse([{:stop, data} | acc])

          {:agent, ^agent_pid, :error, response} ->
            Enum.reverse([{:error, response} | acc])

          {:agent, ^agent_pid, :cancelled, response} ->
            Enum.reverse([{:cancelled, response} | acc])

          {:agent, ^agent_pid, :pause, data} ->
            Enum.reverse([{:pause, data} | acc])

          {:agent, ^agent_pid, type, data} ->
            collect_events_loop(agent_pid, [{type, data} | acc], timeout)
        after
          timeout -> {:timeout, Enum.reverse(acc)}
        end
      end
    end
  end
end
