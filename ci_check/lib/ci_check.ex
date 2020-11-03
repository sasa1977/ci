defmodule CiCheck do
  def run do
    case Job.run!(&check/0, timeout: :timer.minutes(20)) do
      :ok ->
        IO.puts("\nAll checks succeeded!")

      {:error, errors} ->
        IO.puts("\n")

        errors
        |> List.wrap()
        |> List.flatten()
        |> Enum.each(&IO.puts/1)

        System.halt(1)
    end
  end

  def check,
    do: ~w/ci_check ci/a |> Enum.map(&start_check/1) |> await_tasks()

  defp start_check(component) do
    Job.start_task(fn ->
      set_log_prefix("[#{component}] ")
      check_component(component)
    end)
  end

  defp check_component(:ci_check), do: check_component()

  defp check_component(:ci) do
    set_cwd("..")
    with :ok <- os_cmd("mix deps.get"), do: check_component()
  end

  defp check_component do
    with :ok <- os_cmd("mix compile --warnings-as-errors", env: [{"MIX_ENV", "test"}]) do
      [
        start_os_cmd("mix format --check-formatted", env: [{"MIX_ENV", "test"}]),
        start_os_cmd("mix test")
      ]
      |> await_os_cmds()
    end
  end

  defp await_tasks(tasks) do
    tasks
    |> Enum.map(&Job.await_task/1)
    |> Enum.map(fn result -> with {:ok, result} <- result, do: result end)
    |> combine_results()
  end

  defp os_cmd(cmd, opts \\ []),
    do: cmd |> start_os_cmd(opts) |> await_os_cmd()

  defp start_os_cmd(cmd, opts \\ []) do
    IO.puts("#{log_prefix()}running #{cmd}")

    case Job.start_aux({OsCmd, {cmd, cmd_opts(opts)}}) do
      {:ok, pid} -> %{pid: pid, cmd: cmd}
      {:error, %OsCmd.Error{} = error} -> %{cmd: cmd, error: error}
    end
  end

  defp await_os_cmd(%{error: error}), do: {:error, error.message}

  defp await_os_cmd(cmd) do
    case OsCmd.await(cmd.pid) do
      {:ok, _output} ->
        :ok

      {:error, reason, output} ->
        {:error, "#{log_prefix()}#{cmd.cmd} failed with reason #{reason}:\n#{output}"}
    end
  end

  defp await_os_cmds(cmds),
    do: cmds |> Stream.map(&await_os_cmd/1) |> combine_results()

  defp combine_results(results) do
    case for {:error, error} <- results, do: error do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp set_log_prefix(prefix), do: Process.put({__MODULE__, :log_prefix}, prefix)

  defp log_prefix do
    with <<_, _::binary>> = prefix <- Process.get({__MODULE__, :log_prefix}, ""),
         do: String.pad_leading(prefix, 11)
  end

  defp set_cwd(cwd), do: Process.put({__MODULE__, :cwd}, cwd)
  defp cwd, do: Process.get({__MODULE__, :cwd}, ".")

  defp cmd_opts(opts) do
    Keyword.merge(
      [pty: true, notify: self(), cd: cwd()],
      opts
    )
  end
end
