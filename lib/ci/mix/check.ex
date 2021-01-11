defmodule Mix.Tasks.Ci.Check do
  use Mix.Task

  alias Job.Pipeline

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ci)

    Job.run(
      {Pipeline,
       {:sequence,
        [
          mix("compile --warnings-as-errors"),
          {:parallel, [mix("dialyzer"), mix("test"), mix("format --check-formatted")]}
        ]}},
      timeout: :timer.minutes(10)
    )
    |> report_errors()
  end

  defp report_errors({:ok, _}), do: Mix.shell().info("All the checks have passed 🎉")

  defp report_errors({:error, errors}) do
    [errors]
    |> List.flatten()
    |> Enum.map(& &1.message)
    |> Enum.join("\n\n")
    |> to_string()
    |> Mix.raise()
  end

  defp mix(arg, opts \\ []), do: cmd("mix #{arg}", opts)

  defp cmd(cmd, opts) do
    handler = &log(message(&1, cmd))
    cmd_opts = [handler: handler] ++ Keyword.merge([pty: true, env: [{"MIX_ENV", "test"}]], opts)
    {OsCmd, {cmd, cmd_opts}}
  end

  defp log(message), do: IO.write(message)

  defp message(:starting, cmd), do: "starting #{cmd}\n"
  defp message({:output, output}, _cmd), do: output
  defp message({:stopped, status}, cmd), do: "#{cmd} finished with status #{status}\n\n"
end
