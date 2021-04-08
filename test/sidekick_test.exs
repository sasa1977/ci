defmodule SidekickTest do
  use ExUnit.Case, async: false

  test "starts a remote node" do
    assert Sidekick.start(:test, []) == :ok

    # Sidekick node should exist
    assert Node.list() == [:"test@127.0.0.1"]

    # Supervisor should be started on the Node
    pid = GenServer.whereis({Sidekick.Supervisor, :"test@127.0.0.1"})
    assert pid != nil

    # Shutting down the supervisor should close down the node
    Node.monitor(:"test@127.0.0.1", true)
    Supervisor.stop(pid)
    assert_receive {:nodedown, :"test@127.0.0.1"}, 2000
    assert Node.list() == []
  end
end
