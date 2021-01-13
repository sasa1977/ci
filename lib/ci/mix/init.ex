defmodule Mix.Tasks.Ci.Init do
  use Mix.Task

  ci_template_file = Path.join(__DIR__, "ci.ex.eex")
  @external_resource ci_template_file

  @ci_template EEx.compile_file(ci_template_file)

  @impl Mix.Task
  def run(_args) do
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)

    {content, _} = Code.eval_quoted(@ci_template, app: app)
    path = Path.join(["lib", "mix", to_string(app), "ci.ex"])
    Mix.Generator.create_file(path, content)
  end
end
