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
    case System.cmd("docker", ["run", "-dt", args], stderr_to_stdout: true) do
      {id, 0} ->
        container_id = String.trim(id)
        monitor_ref = Process.monitor(from)
        state = Map.put(state, from, {container_id, monitor_ref})
        {:reply, {:ok, container_id}, state}

      {msg, _} ->
        {:reply, {:error, msg}, state}
    end
  end

  @impl true
  def handle_call({:stop, container_id}, {_from, _ref}, state) do
    {pid, {container_id, monitor_ref}} =
      state
      |> Map.to_list()
      |> Enum.find(fn {_pid, {state_container_id, _monitor_ref}} ->
        container_id == state_container_id
      end)

    case remove_container(container_id, monitor_ref, pid) do
      :ok -> {:reply, :ok, Map.delete(state, pid)}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:list, {_from, _ref}, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Logger.debug("Received down from #{inspect(pid)}")
    {container_id, monitor_ref} = Map.fetch!(state, pid)

    case remove_container(container_id, monitor_ref, pid) do
      :ok -> {:noreply, Map.delete(state, pid)}
      # TODO how to handle containers that failed to shutdown
      :error -> {:noreply, state}
    end
  end

  # We needs to ignore port shutdown when calling System.cmd
  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug(
      "Now terminating #{__MODULE__} because of #{inspect(reason)} with state: #{inspect(state)}"
    )

    # TODO how to handle containers that failed to shutdown
    Enum.reduce(state, state, fn {pid, {container_id, monitor_ref}}, state ->
      case remove_container(container_id, monitor_ref, pid) do
        :ok -> Map.delete(state, pid)
        :error -> state
      end
    end)

    Logger.debug("#{__MODULE__} Terminated")
  end

  defp remove_container(container_id, monitor_ref, pid) do
    Logger.debug(
      "Shuting down container with id #{inspect(container_id)} controlled by process #{
        inspect(pid)
      }"
    )

    Process.demonitor(monitor_ref)

    case System.cmd("docker", ["rm", "-f", container_id]) do
      {container_id, 0} ->
        Logger.debug("#{container_id} shutdown")
        :ok

      {msg, _} ->
        Logger.debug("#{container_id} failed to shutdown")
        {:error, msg}
    end
  end
end
