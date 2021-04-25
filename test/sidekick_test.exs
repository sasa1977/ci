defmodule SidekickTest do
  use ExUnit.Case, async: false

  test "starts a remote node" do
    :net_kernel.monitor_nodes(true)
    # Sidekick node should exist
    {:ok, _pid} = Sidekick.start_link(:test, [])
    assert_receive {:nodeup, :"test@127.0.0.1"}, 2000

    # Supervisor should be started on the Node
    assert :rpc.call(:"test@127.0.0.1", Process, :whereis, [Sidekick.Supervisor]) != nil

    # Shutting down the supervisor should close down the node
    Node.monitor(:"test@127.0.0.1", true)
    Supervisor.stop({Sidekick.Supervisor, :"test@127.0.0.1"})
    assert_receive {:nodedown, :"test@127.0.0.1"}, 2000
    assert Node.list() == []
  end

  test "shutting call process should kill sidekick" do
    :net_kernel.monitor_nodes(true)
    {:ok, pid} = Sidekick.start_link(:test, [])

    assert_receive {:nodeup, :"test@127.0.0.1"}, 2000

    GenServer.stop(pid)

    assert_receive {:nodedown, :"test@127.0.0.1"}, 5000
  end
end
