defmodule Ci.MixProject do
  use Mix.Project

  @version "0.1.1"

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
      docs: docs(),
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      compile: [&gen_boot/1, "compile"]
    ]
  end

  defp gen_boot(_) do
    Mix.shell().info("Generating node.rel file")

    apps =
      [:kernel, :stdlib, :elixir, :compiler]
      |> Enum.map(&{&1, get_version(&1)})

    rel_spec = {:release, {'node', '0.1.0'}, {:erts, :erlang.system_info(:version)}, apps}
    File.write!("priv/node.rel", consultable(rel_spec))

    Mix.shell().info("Generating node.boot file")
    :systools.make_script('priv/node', [:silent])
  end

  defp consultable(term) do
    IO.chardata_to_string(:io_lib.format("%% coding: utf-8~n~tp.~n", [term]))
  end

  defp get_version(app) do
    path = :code.lib_dir(app)
    {:ok, [{:application, ^app, properties}]} = :file.consult(Path.join(path, "ebin/#{app}.app"))
    Keyword.fetch!(properties, :vsn)
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
      source_url: "https://github.com/sasa1977/ci/",
      source_ref: @version
    ]
  end

  defp package() do
    [
      description: "CI/CD toolkit as an Elixir library",
      maintainers: ["Saša Jurić"],
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README* LICENSE* CHANGELOG* ports),
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
