import Config

config :ash,
  default_string_length_count: :codepoints,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

if Mix.env() == :test do
  # The suite deliberately exercises failure paths; their logging is noise.
  config :logger, level: :critical

  config :ash_workflow,
    ash_domains: [AshWorkflowTest.Domain, AshWorkflowTest.Postgres.Domain],
    ecto_repos: [AshWorkflowTest.Repo]

  config :ash_workflow, AshWorkflowTest.Repo,
    username: System.get_env("POSTGRES_USER", "postgres"),
    password: System.get_env("POSTGRES_PASSWORD", "postgres"),
    hostname: System.get_env("POSTGRES_HOST", "localhost"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
    database: "ash_workflow_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10

  # Oban runs inline in tests: `Oban.Testing` drives the queues explicitly so
  # trigger execution is deterministic rather than time-dependent.
  config :ash_workflow, Oban,
    repo: AshWorkflowTest.Repo,
    testing: :manual,
    # :workflow is the DSL default; :hiring_pipeline comes from the fixture
    # that overrides the queue.
    queues: [workflow: 10, hiring_pipeline: 10],
    plugins: [{Oban.Plugins.Cron, []}]

  config :ash_oban, pro?: false
end
