defmodule SidekickTest do
  use ExUnit.Case

  test "foo" do
    Sidekick.start([]) |> IO.inspect()
    assert_receive :foo
  end
end
