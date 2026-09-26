import Config

config :document_approval,
  ash_domains: [DocumentApproval.Domain],
  ecto_repos: [DocumentApproval.Repo]

config :document_approval, DocumentApproval.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "document_approval_#{config_env()}"

config :document_approval, Oban,
  repo: DocumentApproval.Repo,
  queues: [workflow: 10],
  plugins: [{Oban.Plugins.Cron, []}]

config :ash_oban, pro?: false

# Ash 3.33.11 requires a choice. Codepoints is what SQL data layers count.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  config :document_approval, DocumentApproval.Repo, pool: Ecto.Adapters.SQL.Sandbox

  # Oban queues are drained explicitly by the tests so trigger execution is
  # deterministic rather than time-dependent.
  config :document_approval, Oban, testing: :manual

  config :logger, level: :warning
end
