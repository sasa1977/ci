defmodule OsCmd.Process do
  def start(args, opts \\ []) do
    with {:ok, port_executable} <- port_executable() do
      process =
        Port.open({:spawn_executable, port_executable}, [
          :stderr_to_stdout,
          :exit_status,
          :binary,
          args: args(opts) ++ args
        ])

      receive do
        {^process, {:data, "os_cmd: started\n"}} ->
          {:ok, process}

        {^process, {:exit_status, _exit_code}} ->
          message =
            Stream.repeatedly(fn ->
              receive do
                {^process, {:data, data}} -> data
              after
                0 -> nil
              end
            end)
            |> Stream.take_while(&(not is_nil(&1)))
            |> Enum.join()

          {:error, %OsCmd.Error{message: message}}
      end
    end
  end

  def stop(process, timeout \\ :timer.seconds(5)) do
    with {:connected, pid} <- Port.info(process, :connected) do
      if pid != self(), do: raise("Only the owner process can stop the command")
      Port.command(process, "stop\n")

      receive do
        {^process, {:exit_status, _exit_code}} -> :ok
      after
        timeout ->
          Port.close(process)
      end
    end

    :ok
  end

  def handle_message(process, {process, {:data, data}}), do: {:output, data}
  def handle_message(process, {process, {:exit_status, exit_code}}), do: {:stopped, exit_code}
  def handle_message(_process, _other), do: nil

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
      _ -> {:error, %OsCmd.Error{message: "can't find os_cmd executable"}}
    end
  end
end
