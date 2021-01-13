defmodule Mix.Tasks.Ci.Check do
  @moduledoc false

  use Mix.Task
  import IO.ANSI
  alias Job.Pipeline

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ci)
    setup_telemetry()

    Job.run(
      Pipeline.sequence([
        mix("compile --warnings-as-errors"),
        Pipeline.parallel([
          mix("dialyzer"),
          mix("test"),
          mix("format --check-formatted"),
          mix("docs", env: [mix_env: "dev"])
        ])
      ]),
      timeout: :timer.minutes(10),
      telemetry_id: [:ci]
    )
    |> report_errors()
  end

  defp setup_telemetry,
    do: :telemetry.attach_many("handler", [[:ci, :stop], [:cmd, :stop]], &report_duration/4, nil)

  defp report_duration(event, %{duration: duration}, meta, _config),
    do: info("#{event_name(event, meta)} took #{format_duration(duration)} seconds")

  defp event_name([:ci, :stop], _meta), do: "CI checks"
  defp event_name([:cmd, :stop], meta), do: meta.cmd

  defp format_duration(duration) do
    duration = div(System.convert_time_unit(duration, :native, :millisecond), 100)
    if rem(duration, 10) == 0, do: div(duration, 10), else: Float.round(duration / 10, 1)
  end

  defp report_errors({:ok, _}), do: info("All the checks have passed 🎉")

  defp report_errors({:error, errors}),
    do: [errors] |> List.flatten() |> Enum.map(&error/1) |> Enum.join("\n") |> Mix.raise()

  defp error(%OsCmd.Error{message: message}), do: message
  defp error(other), do: inspect(other)

  defp mix(arg, opts \\ []),
    do: cmd("mix #{arg}", Config.Reader.merge([env: [mix_env: "test"]], opts))

  defp cmd(cmd, opts) do
    handler = &log(message(&1, cmd))
    cmd_opts = [handler: handler, telemetry_id: [:cmd]] ++ Keyword.merge([pty: true], opts)
    OsCmd.action(cmd, cmd_opts)
  end

  defp log(message), do: IO.write(message)

  defp message(:starting, cmd), do: [blue(), "starting #{cmd}\n", reset()]
  defp message({:output, output}, _cmd), do: output
  defp message({:stopped, _status}, _cmd), do: ""

  defp info(message), do: Mix.shell().info([bright(), blue(), message, reset()])
end
