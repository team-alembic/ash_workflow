import Config

config :order_fulfilment,
  ash_domains: [OrderFulfilment.Domain],
  ecto_repos: [OrderFulfilment.Repo]

config :order_fulfilment, OrderFulfilment.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "order_fulfilment_#{config_env()}"

config :order_fulfilment, Oban,
  repo: OrderFulfilment.Repo,
  queues: [fulfilment: 10],
  plugins: [{Oban.Plugins.Cron, []}]

config :ash_oban, pro?: false

if config_env() == :test do
  config :order_fulfilment, OrderFulfilment.Repo, pool: Ecto.Adapters.SQL.Sandbox

  # Oban queues are drained explicitly by the tests so trigger execution is
  # deterministic rather than time-dependent.
  config :order_fulfilment, Oban, testing: :manual

  config :logger, level: :warning
end
