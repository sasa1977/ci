defmodule SidekickTest do
  use ExUnit.Case, async: false

  test "starts a remote node" do
    assert Sidekick.start([]) == :ok
  end
end
