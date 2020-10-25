defmodule Mix.Tasks.Compile.OsCmd do
  use Mix.Task.Compiler

  @recursive true

  @impl Mix.Task.Compiler
  def run(_argv) do
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

      {output, _exit_code} ->
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
