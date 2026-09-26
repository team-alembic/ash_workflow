import Config

config :workflow_timeline,
  ecto_repos: [WorkflowTimeline.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :workflow_timeline, WorkflowTimelineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: WorkflowTimelineWeb.ErrorHTML, json: WorkflowTimelineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WorkflowTimeline.PubSub,
  live_view: [signing_salt: "6bK9wYQm"]

config :esbuild,
  version: "0.17.11",
  workflow_timeline: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  workflow_timeline: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :workflow_timeline, ash_domains: [WorkflowTimeline.IncidentResponse]

config :workflow_timeline, Oban,
  engine: Oban.Engines.Basic,
  queues: [default: 10, workflow: 10],
  repo: WorkflowTimeline.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

config :ash_oban, pro?: false

config :ash,
  include_embedded_source_by_default?: false,
  # Ash 3.33.11 requires a choice. Codepoints is what SQL data layers count.
  default_string_length_count: :codepoints

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [:resource, :attributes, :relationships, :actions, :policies, :workflow]
    ]
  ]

import_config "#{config_env()}.exs"
