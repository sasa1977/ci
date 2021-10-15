defmodule ContainerTest do
  alias ManagedDocker.Container
  use ExUnit.Case, async: true

  test "Start and stop container" do
    :net_kernel.start([:"test@127.0.0.1"])
    start_supervised!(Container)
    assert {:ok, container_id} = Container.run(:test, "alpine")

    process_id = self()
    assert {:ok, %{^process_id => {^container_id, _ref}}} = Container.list(:test)

    resp = fetch_docker_ps(container_id)
    # docker ps returns 11 char shortcode for the container id
    assert String.contains?(resp, String.slice(container_id, 0..11))

    assert :ok = Container.stop(:test, container_id)

    assert {:ok, %{}} == Container.list(:test)
  end

  test "If owner process is stopped then container is stopped" do
    :net_kernel.start([:"test@127.0.0.1"])
    start_supervised!(Container)

    container_pid = Process.whereis(Container)
    {:ok, pid} = Agent.start(fn -> Container.run(:test, "alpine") end)
    {:ok, pid2} = Agent.start(fn -> Container.run(:test, "alpine") end)

    # Both containers should exists
    assert {:ok, container_id} = Agent.get(pid, fn state -> state end)
    assert {:ok, container_id2} = Agent.get(pid2, fn state -> state end)
    assert {:ok, containers} = Container.list(:test)
    assert %{^pid => {^container_id, _ref}, ^pid2 => {^container_id2, _ref2}} = containers

    Agent.stop(pid)
    # Container 1 should be stoped, but 2. container and container process should keep running
    assert {:ok, state} = Container.list(:test)
    assert pid2 in Map.keys(state)
    assert pid not in Map.keys(state)
    assert container_pid == Process.whereis(Container)
  end

  test "Should work on remote node" do
    sidekick_pid = start_supervised!({Sidekick, {:test2, [Container]}})
    assert {:ok, container_id} = Container.run(:test2, "alpine")

    pid = self()
    assert {:ok, %{^pid => {^container_id, _ref}}} = Container.list(:test2)

    # Killing sidekick should clean up
    :net_kernel.monitor_nodes(true)
    resp = fetch_docker_ps(container_id)
    # docker ps returns 11 char shortcode for the container id
    assert String.contains?(resp, String.slice(container_id, 0..11))

    GenServer.stop(sidekick_pid)
    assert_receive {:nodedown, :"test2@127.0.0.1"}, 5000
    resp = fetch_docker_ps(container_id)
    refute String.contains?(resp, String.slice(container_id, 0..11))
  end

  defp fetch_docker_ps(container_id) do
    {resp, 0} = System.cmd("docker", ["ps", "-f", "id=#{container_id}"])
    resp
  end
end
