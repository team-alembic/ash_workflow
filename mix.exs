defmodule AshWorkflow.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      app: :ash_workflow,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:mix_test_watch, "~> 1.2", only: [:dev, :test]},
      {:ash, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_oban, "~> 0.2"},
      {:igniter, "~> 0.6"},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 0.1", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      extras: [
        {"README.md", title: "Home"},
        "documentation/tutorials/getting-started-with-ash-workflow.md",
        "documentation/topics/automatic-vs-manual-steps.md",
        "documentation/topics/timeouts-and-deadlines.md",
        "documentation/topics/authorization.md",
        "documentation/topics/workflows-and-relationships.md",
        "documentation/dsls/DSL-AshWorkflow.md"
      ],
      groups_for_extras: [
        Tutorials: ~r'documentation/tutorials',
        Topics: ~r'documentation/topics',
        DSLs: ~r'documentation/dsls'
      ],
      groups_for_modules: [
        Dsl: [AshWorkflow],
        Entities: [
          AshWorkflow.Entities.Step,
          AshWorkflow.Entities.Transition,
          AshWorkflow.Entities.Timeout
        ],
        Checks: [AshWorkflow.Checks],
        Internals: ~r/.*/
      ]
    ]
  end

  defp aliases do
    [
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshWorkflow"
    ]
  end
end
