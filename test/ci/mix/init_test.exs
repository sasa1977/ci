defmodule Mix.Tasks.Ci.InitTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  @tag :ci
  test "generates a CI which can be executed", context do
    project_path = new_project!(context.tmp_dir, "test")

    assert {:ok, _output} = OsCmd.run("mix ci.init", cd: project_path)

    assert {:ok, output} = OsCmd.run("mix test.ci", cd: project_path)
    assert output =~ "starting mix compile --warnings-as-errors"
    assert output =~ "starting mix test"
    assert output =~ "starting mix format --check-formatted"
    assert output =~ "All the checks have passed"
  end

  defp new_project!(root_folder, project_name) do
    {:ok, _output} = OsCmd.run("mix new #{project_name}", cd: root_folder)

    project_path = Path.join(root_folder, project_name)
    mix_exs_path = Path.join(project_path, "mix.exs")
    mix_content = File.read!(mix_exs_path)

    mix_exs =
      String.replace(
        mix_content,
        ~r/defp deps do.*?end/s,
        ~s/defp deps, do: [{:ci, path: "#{File.cwd!()}"}]/
      )

    File.write!(mix_exs_path, mix_exs)

    {:ok, _output} = OsCmd.run("mix deps.get", cd: project_path)
    {:ok, _output} = OsCmd.run("mix compile", cd: project_path)

    project_path
  end
end
