defmodule Mix.Tasks.Compile.OsCmd do
  @moduledoc false
  use Mix.Task.Compiler

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
    if System.find_executable("go") do
      build_port()
    else
      Mix.shell().info([
        IO.ANSI.yellow(),
        "Can't find `go` executable. `OsCmd` will not work.",
        IO.ANSI.reset()
      ])
    end
  end

  defp build_port do
    target_folder = Path.absname("priv")
    File.mkdir_p!(target_folder)

    System.cmd(
      "go",
      ~w/build -o #{target_folder}/,
      cd: Path.join(~w/ports os_cmd/),
      stderr_to_stdout: true
    )
    |> case do
      {_, 0} ->
        {:ok, []}

      {output, _exit_status} ->
        error = %Mix.Task.Compiler.Diagnostic{
          compiler_name: "os_cmd",
          details: nil,
          file: "unknown",
          message: output,
          position: nil,
          severity: :warning
        }

        Mix.shell().info([:bright, :red, error.message, :reset])
        {:error, [error]}
    end
  end
end
