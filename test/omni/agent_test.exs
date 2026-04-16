defmodule Omni.AgentTest do
  use ExUnit.Case, async: true

  describe "generate_id/0" do
    test "returns a 16-character url-safe base64 string" do
      id = Omni.Agent.generate_id()
      assert is_binary(id)
      assert byte_size(id) == 16
      assert id =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "returns distinct values" do
      ids = for _ <- 1..50, do: Omni.Agent.generate_id()
      assert ids == Enum.uniq(ids)
    end
  end
end
