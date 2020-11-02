defmodule Ci.MixProject do
  use Mix.Project

  def project do
    [
      app: :ci,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: Mix.compilers() ++ [:os_cmd]
    ]
  end

  def application do
    [
      mod: {Ci.App, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mox, "~> 1.0"},
      {:nimble_parsec, "~> 1.1"},
      {:parent, "~> 0.11"}
    ]
  end
end
