import Config

config :subscription_dunning,
  ash_domains: [SubscriptionDunning.Domain],
  ecto_repos: [SubscriptionDunning.Repo]

config :subscription_dunning, SubscriptionDunning.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "subscription_dunning_#{config_env()}"

config :subscription_dunning, Oban,
  repo: SubscriptionDunning.Repo,
  queues: [workflow: 10],
  plugins: [{Oban.Plugins.Cron, []}]

config :ash_oban, pro?: false

# Ash 3.33.11 requires a choice. Codepoints is what SQL data layers count.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  config :subscription_dunning, SubscriptionDunning.Repo, pool: Ecto.Adapters.SQL.Sandbox

  # Oban queues are drained explicitly by the tests so trigger execution is
  # deterministic rather than time-dependent.
  config :subscription_dunning, Oban, testing: :manual

  config :logger, level: :warning
end
