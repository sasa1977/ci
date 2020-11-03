defmodule CiCheck do
  def run do
    with {:error, reason} <- Job.run!(&check/0, timeout: :timer.minutes(20)),
         do: raise(reason)
  end

  def check do
    with :ok <- os_cmd("mix deps.get"),
         :ok <- os_cmd("mix compile --warnings-as-errors", env: [{"MIX_ENV", "test"}]) do
      [
        start_os_cmd("mix format --check-formatted", env: [{"MIX_ENV", "test"}]),
        start_os_cmd("mix test")
      ]
      |> await_os_cmds()
    end
  end

  defp os_cmd(cmd, opts \\ []),
    do: cmd |> start_os_cmd(opts) |> await_os_cmd()

  defp start_os_cmd(cmd, opts \\ []) do
    case Job.start_aux({OsCmd, {cmd, cmd_opts(opts)}}) do
      {:ok, pid} -> %{pid: pid, cmd: cmd}
      {:error, %OsCmd.Error{} = error} -> %{cmd: cmd, error: error}
    end
  end

  defp await_os_cmd(%{error: error}), do: {:error, error.message}

  defp await_os_cmd(cmd) do
    case OsCmd.await(cmd.pid) do
      {:ok, _output} -> :ok
      {:error, reason, _output} -> {:error, reason}
    end
  end

  defp await_os_cmds(cmds) do
    errors =
      for cmd <- cmds,
          {:error, error} <- [await_os_cmd(cmd)],
          do: "#{cmd.cmd} exited with status #{error}"

    case errors do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp cmd_opts(opts) do
    Keyword.merge(
      [notify: self(), cd: "..", handler: &handle_command_event/1],
      opts
    )
  end

  defp handle_command_event({:output, output}), do: IO.write(output)
  defp handle_command_event({:stopped, _}), do: :ok
end
