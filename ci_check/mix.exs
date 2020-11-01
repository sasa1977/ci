defmodule CiCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :ci_check,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ci, path: ".."},
      {:parent, "~> 0.11"}
    ]
  end
end
