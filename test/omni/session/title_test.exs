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
        "This is a much longer message that exceeds the sixty-four character truncation limit and should be cut"

      messages = [text_message(:user, long_text)]

      assert {:ok, title} = Title.generate(:heuristic, messages)
      assert String.ends_with?(title, "...")
      assert String.length(title) <= 67
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

  describe "generate(:heuristic, ...) with title_seed" do
    defp seeded_message(text, seed) do
      %Omni.Message{
        role: :user,
        content: [%Omni.Content.Text{text: text}],
        private: %{title_seed: seed}
      }
    end

    test "title_seed wins over message content" do
      messages = [seeded_message("<ctx>noise</ctx> actual question", "Clean seed title")]
      assert {:ok, "Clean seed title"} = Title.generate(:heuristic, messages)
    end

    test "title_seed is truncated like content" do
      seed =
        "A deliberately long seed that overruns the sixty-four character limit for titles"

      assert {:ok, title} = Title.generate(:heuristic, [seeded_message("hi", seed)])
      assert String.ends_with?(title, "...")
      assert String.length(title) <= 67
    end

    test "title_seed is not XML-stripped" do
      messages = [seeded_message("hi", "<b>seed with markup</b>")]
      assert {:ok, "<b>seed with markup</b>"} = Title.generate(:heuristic, messages)
    end

    test "blank or non-string title_seed falls through to content" do
      assert {:ok, "from content"} =
               Title.generate(:heuristic, [seeded_message("from content", "   ")])

      assert {:ok, "from content"} =
               Title.generate(:heuristic, [seeded_message("from content", 42)])
    end
  end

  describe "generate(:heuristic, ...) XML stripping" do
    test "strips a leading context block down to the real message" do
      text = """
      <context_history data="2026-07-30">
      some context
      </context_history>

      username: @bot_name Actual message here
      """

      messages = [text_message(:user, text)]

      assert {:ok, "username: @bot_name Actual message here"} =
               Title.generate(:heuristic, messages)
    end

    test "strips stacked leading blocks, nesting, and self-closing tags" do
      text = "<ctx><inner>a</inner>b</ctx>\n<mem attr=\"v\"/> the question"
      messages = [text_message(:user, text)]
      assert {:ok, "the question"} = Title.generate(:heuristic, messages)
    end

    test "leaves malformed leading XML untouched" do
      messages = [text_message(:user, "<unclosed>rest of the message")]
      assert {:ok, "<unclosed>rest of the message"} = Title.generate(:heuristic, messages)
    end

    test "leaves inline and trailing markup untouched" do
      messages = [text_message(:user, "compare <a>x</a> with <b>y</b>")]
      assert {:ok, "compare <a>x</a> with <b>y</b>"} = Title.generate(:heuristic, messages)
    end

    test "skips an XML-only message and uses the next content-bearing one" do
      messages = [
        text_message(:user, "<ctx>only markup</ctx>"),
        text_message(:assistant, "Here is the answer")
      ]

      assert {:ok, "Here is the answer"} = Title.generate(:heuristic, messages)
    end

    test "returns {:error, :no_text} when every message is XML-only" do
      messages = [text_message(:user, "<a>x</a>"), text_message(:assistant, "<b>y</b>")]
      assert {:error, :no_text} = Title.generate(:heuristic, messages)
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
