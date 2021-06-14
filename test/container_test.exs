defmodule ContainerTest do
  alias ManagedDocker.Container
  use ExUnit.Case, async: true

  test "Start and stop container" do
    :net_kernel.start([:"test@127.0.0.1"])
    start_supervised!(Container)
    assert {:ok, container_id} = Container.run(:test, "alpine")

    process_id = self()

    assert {:ok, %{^process_id => {^container_id, _ref}}} = Container.list(:test)

    assert :ok = Container.stop(:test, container_id)

    assert {:ok, %{}} == Container.list(:test)
  end

  test "If process is stopped then container is stopped" do
    :net_kernel.start([:"test@127.0.0.1"])
    start_supervised!(Container)

    container_pid = Process.whereis(Container)
    {:ok, pid} = Agent.start(fn -> Container.run(:test, "alpine") end)
    {:ok, pid2} = Agent.start(fn -> Container.run(:test, "alpine") end)

    assert {:ok, container_id} = Agent.get(pid, fn state -> state end)
    assert {:ok, container_id2} = Agent.get(pid2, fn state -> state end)

    assert {:ok, %{^pid => {^container_id, _ref}}} = Container.list(:test)

    Agent.stop(pid)

    assert :ok = Container.stop(:test, container_id2)

    assert container_pid == Process.whereis(Container)
  end

  test "Start on remote node" do
    pid = start_supervised!({Sidekick, {:test2, [Container]}})
    assert {:ok, container_id} = Container.run(:test2, "alpine")

    GenServer.stop(pid)
  end
end
