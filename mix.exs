defmodule AshWorkflow.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/team-alembic/ash_workflow"

  @description """
  Declarative workflow orchestration for the Ash Framework — multi-step
  workflows combining human actions, background jobs, and time-based deadlines.
  """

  def project do
    [
      app: :ash_workflow,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      usage_rules: usage_rules(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      # Transformers and verifiers run while the test fixtures compile, which is
      # before `cover` starts tracking, so their reported coverage understates
      # how well they are tested. The threshold guards against regression rather
      # than asserting a meaningful absolute level.
      test_coverage: [
        summary: [threshold: 65],
        ignore_modules: [
          # Modules AshWorkflow generates into consuming resources, plus the
          # Spark-generated option structs. Coverage of these reflects the
          # fixtures that happen to exist, not how well the library is tested.
          ~r/\.AshWorkflow\.(Workers|Schedulers)($|\.)/,
          ~r/^AshWorkflow\.Workflow($|\.)/,
          # Test fixtures and the compiled examples.
          ~r/^AshWorkflowTest($|\.)/,
          ~r/^ATS($|\.)/,
          ~r/^BasicWorkflow($|\.)/,
          ~r/^Example($|\.)/,
          ~r/^Inspect\./
        ]
      ],

      # Hex
      description: @description,
      package: package(),

      # Docs
      name: "AshWorkflow",
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support", "examples"]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "ash_workflow",
      maintainers: ["Alembic Pty Ltd"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Ash Framework" => "https://ash-hq.org"
      },
      files:
        ~w[lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* documentation usage-rules.md usage-rules]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp usage_rules do
    [
      file: ".rules/usage-rules.md",
      usage_rules: [~r/.*/]
    ]
  end

  defp deps do
    [
      {:mix_test_watch, "~> 1.2", only: [:dev, :test]},
      {:ash, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_oban, "~> 0.2"},
      # `runtime: false` because igniter is only ever used at compile time, by
      # the mix tasks. Without it, a project depending on this library by path
      # — every demo — inherits igniter as an application to start, and fails
      # with "could not find application file: igniter.app" whenever the
      # optional dep was fetched but not compiled.
      {:igniter, "~> 0.6", optional: true, runtime: false},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},

      # Postgres + Oban integration tests
      {:ash_postgres, "~> 2.0", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: [
        {"README.md", title: "Home"},
        "documentation/tutorials/getting-started-with-ash-workflow.md",
        "documentation/topics/automatic-vs-manual-steps.md",
        "documentation/topics/error-handling.md",
        "documentation/topics/timeouts-and-deadlines.md",
        "documentation/topics/workflow-history.md",
        "documentation/topics/authorization.md",
        "documentation/topics/workflows-and-relationships.md",
        "documentation/topics/bpmn-comparison.md",
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
      test: ["ash.setup --quiet", "test"],
      "test.reset": ["ecto.drop --quiet", "test"],
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshWorkflow"
    ]
  end
end
