# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_workflow_demo,
  ecto_repos: [AshWorkflowDemo.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configures the endpoint
config :ash_workflow_demo, AshWorkflowDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AshWorkflowDemoWeb.ErrorHTML, json: AshWorkflowDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AshWorkflowDemo.PubSub,
  live_view: [signing_salt: "u9oboqJt"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  ash_workflow_demo: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  ash_workflow_demo: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
config :ash_workflow_demo, ash_domains: [AshWorkflowDemo.ATS]

config :ash, include_embedded_source_by_default?: false

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [:resource, :attributes, :relationships, :actions, :policies, :workflow]
    ]
  ]

import_config "#{config_env()}.exs"
