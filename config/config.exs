import Config

config :ash,
  include_embedded_source_by_default?: false,
  default_string_length_count: :codepoints,
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

  # The recipe fixture domains are listed in `:ash_domains` because
  # `Ash.Domain.Igniter` only edits a domain listed there. Without them, a
  # recipe task does not recognise the fixture as a domain and adds a second
  # `use Ash.Domain` to it. `test_helper.exs` leaves them out of the Oban
  # config, and the Postgres fixture sets `migrate? false`.
  recipe_fixture_domains = [
    AshWorkflowTest.RecipeFixtures.Acknowledgement.Domain,
    AshWorkflowTest.RecipeFixtures.Approval.Domain,
    AshWorkflowTest.RecipeFixtures.Expiry.Domain,
    AshWorkflowTest.RecipeFixtures.TransitionLog.Domain,
    AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresDomain
  ]

  config :ash_workflow,
    ash_domains:
      [AshWorkflowTest.Domain, AshWorkflowTest.Postgres.Domain] ++ recipe_fixture_domains,
    recipe_fixture_domains: recipe_fixture_domains,
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
