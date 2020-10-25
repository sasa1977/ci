defmodule OsCmd do
  use GenServer

  defmodule Error do
    defexception [:message, :exit_code]
  end

  def start_link(args) when is_list(args), do: start_link({args, []})

  def start_link({args, opts}),
    do: GenServer.start_link(__MODULE__, {args, opts}, Keyword.take(opts, [:name]))

  def stop(server, reason \\ :normal, timeout \\ :infinity),
    do: GenServer.stop(server, reason, timeout)

  @impl GenServer
  def init({args, opts}) do
    Process.flag(:trap_exit, true)

    case open_port(args, opts) do
      {:ok, port} -> {:ok, %{port: port, notify: Keyword.get(opts, :notify)}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state) do
    if not is_nil(state.notify), do: send(state.notify, {self(), {:stopped, exit_status}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, message}}, %{port: port} = state) do
    if not is_nil(state.notify), do: send(state.notify, {self(), :erlang.binary_to_term(message)})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, %{port: port}), do: stop_program(port)

  defp open_port(args, opts) do
    with {:ok, port_executable} <- port_executable() do
      port =
        Port.open({:spawn_executable, port_executable}, [
          :stderr_to_stdout,
          :exit_status,
          :binary,
          packet: 4,
          args: args(opts) ++ args
        ])

      receive do
        {^port, {:data, "started"}} ->
          {:ok, port}

        {^port, {:data, "not started " <> error}} ->
          Port.close(port)
          {:error, %Error{message: error}}
      end
    end
  end

  defp args(opts) do
    Enum.flat_map(
      opts,
      fn
        {:cd, dir} -> ["-dir", dir]
        {:kill_cmd, cmd} -> ["-kill_cmd", cmd]
        _other -> []
      end
    )
  end

  defp port_executable do
    Application.app_dir(:ci, "priv")
    |> Path.join("os_cmd*")
    |> Path.wildcard()
    |> case do
      [executable] -> {:ok, executable}
      _ -> {:error, %Error{message: "can't find os_cmd executable"}}
    end
  end

  defp stop_program(port) do
    Port.command(port, "stop")

    receive do
      {^port, {:exit_status, _exit_code}} -> :ok
    end
  end
end
