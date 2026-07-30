defmodule Omni.Session.Title do
  @moduledoc """
  Generates titles for conversations.

  Two strategies are exposed through a single entry point, `generate/3`:

    * **Heuristic** (`:heuristic`) — picks the first content-bearing
      message and truncates its text. No LLM call. A message bears
      content when it has a `private[:title_seed]` string (which wins
      over its content), or when text remains after stripping leading
      well-formed XML — so prompts wrapped in context markup (e.g.
      `<context_history>...</context_history>`) don't produce titles of
      truncated markup. Set a `:title_seed` by prompting with a
      `%Omni.Message{}` (see `Omni.Agent.prompt/3`); the seed is used
      verbatim (truncated, never XML-stripped).
    * **Model** (`Omni.Model.ref()` or `%Omni.Model{}`) — asks the given
      model to summarise the first few turns into a concise title.

  Both branches return `{:error, :no_text}` when no usable text exists.
  Attachments, thinking blocks, tool uses, and tool results are
  filtered out — only text contributes.

  This module is pure: it makes at most one HTTP call (in the model
  branch) and holds no state.
  """

  @heuristic_length 64
  @max_tokens 50

  # One leading well-formed XML element: self-closing, or an open tag
  # with matching close, with (?&elem) recursing for nested elements.
  # Attribute values may not contain < or >; anything malformed simply
  # doesn't match, leaving the text untouched.
  @leading_xml ~r{\A\s*(?<elem><[a-zA-Z_][\w.:-]*(?:\s[^<>]*)?/>|<([a-zA-Z_][\w.:-]*)(?:\s[^<>]*)?>(?:[^<]|(?&elem))*</\2\s*>)}

  @system_prompt """
  You generate concise 3-6 word titles for conversations.
  Reply with only the title. No quotes, no punctuation, no explanation.
  """

  @doc """
  Generates a title for the given conversation.

  When `strategy` is `:heuristic`, truncates the first content-bearing
  message — its `private[:title_seed]` if set, otherwise its text with
  leading well-formed XML stripped (see the moduledoc). When `strategy`
  is an `Omni.Model.ref()` (or `%Omni.Model{}`), asks the model to
  summarise the conversation.

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
    case Enum.find_value(messages, &heuristic_text/1) do
      nil -> {:error, :no_text}
      text -> {:ok, truncate(text, @heuristic_length)}
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

  # The first content-bearing message wins: one carrying a
  # `private[:title_seed]` string (the seed is caller-sanitised — never
  # XML-stripped), or one whose text survives stripping leading XML.
  # A blank or non-string seed falls through to the message's content.
  defp heuristic_text(%Omni.Message{private: %{title_seed: seed}} = msg)
       when is_binary(seed) do
    if String.trim(seed) == "", do: content_text(msg), else: seed
  end

  defp heuristic_text(msg), do: content_text(msg)

  defp content_text(msg) do
    case msg |> extract_text() |> strip_leading_xml() |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp strip_leading_xml(text) do
    stripped = String.replace(text, @leading_xml, "", global: false)
    if stripped == text, do: text, else: strip_leading_xml(stripped)
  end

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
