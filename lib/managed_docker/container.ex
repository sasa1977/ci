defmodule ManagedDocker.Container do
  use GenServer
  require Logger

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    # We need to trap exit, so terminate will be called, see docs
    # terminate/2 is called if the GenServer traps exits (using Process.flag/2) and the parent process sends an exit signal
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  def run(sidekick_node, args, timeout \\ 8000) do
    GenServer.call({__MODULE__, :"#{sidekick_node}@127.0.0.1"}, {:run, args}, timeout)
  end

  def stop(sidekick_node, container_id) do
    GenServer.call({__MODULE__, :"#{sidekick_node}@127.0.0.1"}, {:stop, container_id})
  end

  def list(sidekick_node) do
    GenServer.call({__MODULE__, :"#{sidekick_node}@127.0.0.1"}, :list)
  end

  @impl true
  def handle_call({:run, args}, {from, _ref}, state) do
    {id, _} = System.cmd("docker", ["run", "-dt", args], stderr_to_stdout: true)
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
  def handle_call(:list, {from, _ref}, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    Logger.debug("Got dow")
    {container_id, monitor_ref} = Map.fetch!(state, pid)
    updated_state = cleanup(container_id, monitor_ref, pid, state)

    {:noreply, updated_state}
  end

  def handle_info({:EXIT, _ref, reason}, state) do
    Logger.debug(inspect(reason))
    Logger.debug(inspect(_ref))
    # We will ignore port shutdown from calling System.cmd
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("state #{inspect(state)}")
    Logger.debug("Now terminating #{__MODULE__} #{inspect(reason)}")

    updated_state =
      Enum.reduce(state, state, fn {pid, {container_id, monitor_ref}}, state ->
        cleanup(container_id, monitor_ref, pid, state)
      end)

    Logger.debug("Terminated #{__MODULE__}")

    updated_state
  end

  defp cleanup(container_id, monitor_ref, pid, state) do
    Logger.debug("Shuting down #{inspect(container_id)} #{inspect(pid)}")

    Process.demonitor(monitor_ref)
    {data, 0} = System.cmd("docker", ["rm", "-f", container_id])

    Logger.debug(data)

    Map.delete(state, pid)
  end
end
