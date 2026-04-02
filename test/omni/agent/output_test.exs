defmodule Omni.Agent.OutputTest do
  use Omni.Agent.AgentCase, async: true

  @json_fixture "test/support/fixtures/synthetic/anthropic_json.sse"

  defp character_schema do
    Omni.Schema.object(
      %{
        name: Omni.Schema.string(),
        class: Omni.Schema.string()
      },
      required: [:name, :class]
    )
  end

  describe "structured output" do
    test "turn response carries parsed output" do
      {:ok, agent} = start_agent(fixture: @json_fixture)

      :ok = Agent.prompt(agent, "Create a character", output: character_schema())
      events = collect_events(agent)

      assert {:stop, %Response{} = resp} = List.last(events)
      assert resp.output == %{name: "Kai Nakamura", class: "warrior"}
    end

    test "output is nil when no schema is provided" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Hello!")
      events = collect_events(agent)

      assert {:stop, %Response{} = resp} = List.last(events)
      assert resp.output == nil
    end
  end

  describe "structured output with continuation" do
    test "turn response carries the last step's output" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@json_fixture, @json_fixture, @json_fixture]
        )

      :ok = Agent.prompt(agent, "Create a character", output: character_schema())
      events = collect_events(agent)

      assert {:stop, %Response{} = resp} = List.last(events)
      assert resp.output == %{name: "Kai Nakamura", class: "warrior"}
    end

    test "{:continue} events carry intermediate outputs" do
      {:ok, agent} =
        start_agent_with_module(ContinueAgent,
          fixtures: [@json_fixture, @json_fixture, @json_fixture]
        )

      :ok = Agent.prompt(agent, "Create a character", output: character_schema())
      events = collect_events(agent)

      continue_events = for {:continue, resp} <- events, do: resp
      assert length(continue_events) == 2

      for resp <- continue_events do
        assert resp.output == %{name: "Kai Nakamura", class: "warrior"}
      end
    end
  end
end
