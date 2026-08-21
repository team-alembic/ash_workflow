defmodule DocumentApproval.MixProject do
  use Mix.Project

  def project do
    [
      app: :document_approval,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {DocumentApproval.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash_workflow, path: "../.."},
      {:ash_postgres, "~> 2.0"},
      {:simple_sat, "~> 0.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup"],
      test: ["ash.setup --quiet", "test"],
      "test.reset": ["ecto.drop --quiet", "test"]
    ]
  end
end
