import Config

config :workflow_timeline, WorkflowTimelineWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
