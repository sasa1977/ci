defmodule SidekickTest do
  use ExUnit.Case, async: false

  test "starts a remote node" do
    node = start_node!().node

    # Supervisor should be started on the Node
    assert :rpc.call(node, Process, :whereis, [Sidekick.Supervisor]) != nil

    # Shutting down the supervisor should close down the node
    Supervisor.stop({Sidekick.Supervisor, node})

    assert_receive {:nodedown, ^node}, 2000
    assert Node.list() == []
  end

  test "shutting call process should kill sidekick" do
    %{pid: pid, node: node} = start_node!()
    GenServer.stop(pid)

    assert_receive {:nodedown, ^node}, 5000
  end

  defp start_node!(children \\ []) do
    :net_kernel.monitor_nodes(true)

    node_name = :"test_#{System.unique_integer([:positive, :monotonic])}"
    pid = start_supervised!({Sidekick, {node_name, children}})

    node = :"#{node_name}@127.0.0.1"
    assert_receive {:nodeup, ^node}, 2000

    %{pid: pid, node: node}
  end
end
