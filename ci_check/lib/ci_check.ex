defmodule CiCheck do
  use Parent.GenServer

  def run do
    {:ok, _pid} = Parent.GenServer.start_link(__MODULE__, self())

    receive do
      {:result, :ok} -> :ok
      {:result, {:error, reason}} -> raise reason
    end
  end

  @impl GenServer
  def init(client) do
    Parent.start_child(%{
      id: :check,
      start: {Task, :start_link, [fn -> run_checks(client) end]},
      restart: :temporary,
      ephemeral?: true
    })

    {:ok, nil}
  end

  defp run_checks(client) do
    result =
      with :ok <- run_cmd("mix deps.get"),
           :ok <- run_cmd("mix compile --warnings-as-errors", env: [{"MIX_ENV", "test"}]) do
        [
          start_cmd("mix format --check-formatted", env: [{"MIX_ENV", "test"}]),
          start_cmd("mix test")
        ]
        |> await_cmds()
      end

    send(client, {:result, result})
  end

  defp run_cmd(cmd, opts \\ []), do: cmd |> start_cmd(opts) |> await_cmd()

  defp start_cmd(cmd, opts \\ []) do
    {:ok, pid} =
      Parent.Client.start_child(
        parent(),
        {OsCmd, {cmd, cmd_opts(opts)}},
        id: nil,
        binds_to: [self()],
        restart: :temporary,
        ephemeral?: true
      )

    %{pid: pid, cmd: cmd}
  end

  defp await_cmd(cmd) do
    cmd.pid
    |> OsCmd.events()
    |> Stream.map(fn
      {:stopped, 0} -> :ok
      {:stopped, exit_status} -> {:error, "#{cmd.cmd} exited with status #{exit_status}"}
      {:terminated, reason} -> {:error, "#{cmd.cmd} terminated with reason #{inspect(reason)}"}
      _other -> nil
    end)
    |> Enum.find(& &1)
  end

  defp await_cmds(cmds) do
    for cmd <- cmds, result = await_cmd(cmd), result != :ok do
      {:error, error} = result
      error
    end
    |> case do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp cmd_opts(opts) do
    Keyword.merge(
      [
        cd: "..",
        timeout: :timer.minutes(1),
        handler: &handle_command_event/1,
        notify: self()
      ],
      opts
    )
  end

  defp parent, do: hd(Process.get(:"$ancestors"))

  defp handle_command_event({:output, output}), do: IO.write(output)
  defp handle_command_event({:stopped, _}), do: :ok
end
