weather_map = %{
  "London" => "Cloudy with light drizzle, mild temperatures around 8°C.",
  "New York" => "Partly sunny, cold and breezy, highs near 2°C.",
}

weather_tool =
  Omni.tool(
    name: "get_weather",
    description: "Gets the current weather for a city",
    input_schema: %{
      type: "object",
      properties: %{city: %{type: "string", description: "City name"}},
      required: ["city"]
    },
    handler: fn input -> Map.get(weather_map, input[:city]) end
  )

{:ok, pid} = Omni.Agent.start_link(
  model: {:anthropic, "claude-haiku-4-5"},
  tools: [weather_tool]
)

{:ok, _snapshot} = Omni.Agent.subscribe(pid)
:ok = Omni.Agent.prompt(pid, "What is the weather like in London?")

defmodule Loop do
  def listen(pid) do
    receive do
  	  {:agent, ^pid, :stop, response} ->
  			IO.puts "==== DONE ===="
  			dbg response

      {:agent, ^pid, :error, error} ->
        IO.puts "==== ERROR ===="
   		  dbg error

      {:agent, ^pid, event_type, _event} ->
  		  dbg event_type
  		  listen(pid)
    end
  end
end

Loop.listen(pid)
GenServer.stop(pid, :normal)
IO.puts "...end"
