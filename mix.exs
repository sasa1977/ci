defmodule Ci.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ci,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: Mix.compilers() ++ [:os_cmd],
      preferred_cli_env: preferred_cli_env(),
      dialyzer: dialyzer(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Ci.App, []},
      extra_applications: [:eex, :logger]
    ]
  end

  defp deps do
    [
      {:dialyxir, "~> 1.0", only: :test, runtime: false},
      {:ex_doc, "~> 0.23", only: :dev},
      {:mox, "~> 1.0"},
      {:nimble_parsec, "~> 1.1"},
      {:parent, "~> 0.12.0"},
      {:telemetry, "~> 0.4"}
    ]
  end

  defp preferred_cli_env,
    do: [dialyzer: :test]

  defp dialyzer, do: [plt_add_apps: [:mix]]

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      groups_for_modules: [Job: ~r/Job((\..+)|$)/],
      source_ref: @version
    ]
  end

  defp package() do
    [
      description: "CI/CD toolkit as an Elixir library",
      maintainers: ["Saša Jurić"],
      licenses: ["MIT"],
      links: %{
        "Github" => "https://github.com/sasa1977/ci",
        "Changelog" =>
          "https://github.com/sasa1977/ci/blob/#{@version}/CHANGELOG.md##{
            String.replace(@version, ".", "")
          }"
      }
    ]
  end
end
