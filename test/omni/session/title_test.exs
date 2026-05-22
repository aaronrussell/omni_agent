defmodule Omni.Session.TitleTest do
  use ExUnit.Case, async: true

  alias Omni.Session.Title

  defp text_message(role, text) do
    %Omni.Message{role: role, content: [%Omni.Content.Text{text: text}]}
  end

  defp tool_use_message do
    %Omni.Message{
      role: :assistant,
      content: [%Omni.Content.ToolUse{id: "1", name: "get_weather", input: %{}}]
    }
  end

  # ── Heuristic ──────────────────────────────────────────────────

  describe "generate(:heuristic, ...)" do
    test "returns truncated first text message" do
      messages = [text_message(:user, "Hello, how are you doing today?")]
      assert {:ok, "Hello, how are you doing today?"} = Title.generate(:heuristic, messages)
    end

    test "truncates at word boundary with ellipsis" do
      long_text =
        "This is a much longer message that exceeds the fifty character truncation limit and should be cut"

      messages = [text_message(:user, long_text)]

      assert {:ok, title} = Title.generate(:heuristic, messages)
      assert String.ends_with?(title, "...")
      assert String.length(title) <= 53
    end

    test "normalizes whitespace" do
      messages = [text_message(:user, "  hello   world  ")]
      assert {:ok, "hello world"} = Title.generate(:heuristic, messages)
    end

    test "skips non-text messages to find first text" do
      messages = [tool_use_message(), text_message(:assistant, "Here is the answer")]
      assert {:ok, "Here is the answer"} = Title.generate(:heuristic, messages)
    end

    test "returns {:error, :no_text} with no text messages" do
      messages = [tool_use_message()]
      assert {:error, :no_text} = Title.generate(:heuristic, messages)
    end

    test "returns {:error, :no_text} with empty messages list" do
      assert {:error, :no_text} = Title.generate(:heuristic, [])
    end
  end

  # ── LLM ────────────────────────────────────────────────────────

  describe "generate(model_ref, ...)" do
    setup do
      stub_name = :"title_test_#{System.unique_integer([:positive])}"
      model = {:anthropic, "claude-haiku-4-5"}
      {:ok, stub_name: stub_name, model: model}
    end

    test "generates title via LLM", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        body = File.read!("test/support/fixtures/sse/anthropic_text.sse")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      messages = [
        text_message(:user, "Tell me about Elixir"),
        text_message(:assistant, "Elixir is a functional programming language")
      ]

      assert {:ok, title} =
               Title.generate(
                 ctx.model,
                 messages,
                 api_key: "test-key",
                 plug: {Req.Test, ctx.stub_name}
               )

      assert is_binary(title)
      assert String.length(title) > 0
    end

    test "returns {:error, :no_text} when first 4 messages have no text" do
      messages = [tool_use_message(), tool_use_message(), tool_use_message(), tool_use_message()]

      assert {:error, :no_text} =
               Title.generate({:anthropic, "claude-haiku-4-5"}, messages)
    end

    test "propagates API errors", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        body =
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "invalid_request_error", "message" => "bad"}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, body)
      end)

      messages = [text_message(:user, "Hello")]

      assert {:error, _reason} =
               Title.generate(
                 ctx.model,
                 messages,
                 api_key: "test-key",
                 plug: {Req.Test, ctx.stub_name}
               )
    end
  end
end
