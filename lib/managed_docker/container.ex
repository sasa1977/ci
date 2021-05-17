defmodule ManagedDocker.Container do
  use GenServer
  require Logger

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    {:ok, %{}}
  end

  def run(sidekick_node, args, timeout \\ 8000) do
    GenServer.call({__MODULE__, :"#{sidekick_node}@127.0.0.1"}, {:run, args}, timeout)
  end

  def stop(sidekick_node, container_id) do
    GenServer.call({__MODULE__, :"#{sidekick_node}@127.0.0.1"}, {:stop, container_id})
  end

  @impl true
  def handle_call({:run, args}, {from, _ref}, state) do
    {id, _} = System.cmd("docker", ["run", "-dt", args])
    container_id = String.trim(id)
    monitor_ref = Process.monitor(from)
    state = Map.put(state, from, {container_id, monitor_ref})
    {:reply, {:ok, container_id}, state}
  end

  @impl true
  def handle_call({:stop, container_id}, {_from, _ref}, state) do
    {pid, {container_id, monitor_ref}} =
      state
      |> Map.to_list()
      |> Enum.find(fn {_pid, {state_container_id, _monitor_ref}} ->
        container_id == state_container_id
      end)

    updated_state = cleanup(container_id, monitor_ref, pid, state)
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_info({:down, pid}, state) do
    {{container_id, monitor_ref}, state} = Map.pop(state, pid)
    updated_state = cleanup(container_id, monitor_ref, pid, state)
    {:noreply, updated_state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.debug("Now terminating #{__MODULE__}")

    updated_state =
      Enum.reduce(state, state, fn {{pid, {container_id, monitor_ref}}, state} ->
        cleanup(container_id, monitor_ref, pid, state)
      end)

    Logger.debug("Terminated #{__MODULE__}")

    updated_state
  end

  defp cleanup(container_id, monitor_ref, pid, state) do
    Process.demonitor(monitor_ref)
    System.cmd("docker", ["rm", "-f", container_id])
    Map.delete(state, pid)
  end
end
