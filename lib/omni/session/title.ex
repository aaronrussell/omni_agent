defmodule Omni.Session.Title do
  @moduledoc """
  Generates titles for conversations.

  Two strategies are exposed through a single entry point, `generate/3`:

    * **Heuristic** (`:heuristic`) — picks the first message with
      extractable text and truncates it. No LLM call.
    * **Model** (`Omni.Model.ref()` or `%Omni.Model{}`) — asks the given
      model to summarise the first few turns into a concise title.

  Both branches return `{:error, :no_text}` when no message contains any
  `%Omni.Content.Text{}` content. Attachments, thinking blocks, tool
  uses, and tool results are filtered out — only text contributes.

  This module is pure: it makes at most one HTTP call (in the model
  branch) and holds no state.
  """

  @heuristic_length 50
  @max_tokens 50

  @system_prompt """
  You generate concise 3-6 word titles for conversations.
  Reply with only the title. No quotes, no punctuation, no explanation.
  """

  @doc """
  Generates a title for the given conversation.

  When `strategy` is `:heuristic`, falls back to truncating the first
  text-bearing message. When `strategy` is an `Omni.Model.ref()` (or
  `%Omni.Model{}`), asks the model to summarise the conversation.

  Returns `{:error, :no_text}` when no extractable text exists — for the
  model branch, this is checked against the first four messages.

  ## Options

  Options are passed through to `Omni.generate_text/3` when using the
  model strategy. Common options include `:api_key` and `:plug` (for
  testing).
  """
  @spec generate(:heuristic | Omni.Model.t() | Omni.Model.ref(), [Omni.Message.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(strategy, messages, opts \\ [])

  def generate(:heuristic, messages, _opts) when is_list(messages) do
    case Enum.find(messages, &has_text?/1) do
      nil ->
        {:error, :no_text}

      msg ->
        title = msg |> extract_text() |> truncate(@heuristic_length)
        {:ok, title}
    end
  end

  def generate(model, messages, opts) when is_list(messages) do
    if Enum.any?(Enum.take(messages, 4), &has_text?/1) do
      context = Omni.context(system: @system_prompt, messages: [format_prompt(messages)])
      opts = Keyword.put_new(opts, :max_tokens, @max_tokens)

      case Omni.generate_text(model, context, opts) do
        {:ok, response} ->
          case extract_title(response) do
            "" -> {:error, :empty_response}
            title -> {:ok, title}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_text}
    end
  end

  def generate(_strategy, _messages, _opts), do: {:error, :no_text}

  # ── Private ────────────────────────────────────────────────────────

  defp has_text?(%Omni.Message{content: content}) do
    Enum.any?(content, &match?(%Omni.Content.Text{}, &1))
  end

  defp extract_text(%Omni.Message{content: content}) do
    content
    |> Enum.filter(&match?(%Omni.Content.Text{}, &1))
    |> Enum.map_join("\n\n", & &1.text)
    |> String.trim()
  end

  defp extract_title(response) do
    response.message.content
    |> Enum.find_value(fn
      %Omni.Content.Text{text: text} -> text
      _ -> ""
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp format_prompt(messages) do
    conversation_text =
      messages
      |> Enum.take(4)
      |> Enum.chunk_every(2)
      |> Enum.map_join("\n---\n", fn pairs ->
        pairs
        |> Enum.map_join("\n", fn msg ->
          role = msg.role |> to_string() |> String.capitalize()
          "#{role}: #{extract_text(msg)}"
        end)
      end)

    Omni.message("""
    Generate a title for this conversation:
    <conversation>
    #{conversation_text}
    </conversation>
    """)
  end

  defp truncate(text, max) do
    normalized = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(normalized) <= max do
      normalized
    else
      trimmed =
        normalized
        |> String.split(" ", trim: true)
        |> Enum.reduce_while("", fn word, acc ->
          candidate = if acc == "", do: word, else: acc <> " " <> word

          cond do
            String.length(candidate) <= max -> {:cont, candidate}
            acc == "" -> {:halt, String.slice(word, 0, max)}
            true -> {:halt, acc}
          end
        end)

      trimmed <> "..."
    end
  end
end
