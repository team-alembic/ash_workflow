import Config

config :workflow_timeline, WorkflowTimeline.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "workflow_timeline_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :workflow_timeline, WorkflowTimelineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4010],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "P0v2sTQvOa1ZUUYQGm3aHwyG6t9wq2xLwQ4sMSCk1L0X2hHkNwqLQq3f8sJmR9xK",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:workflow_timeline, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:workflow_timeline, ~w(--watch)]}
  ]

config :workflow_timeline, WorkflowTimelineWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/workflow_timeline_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :workflow_timeline, dev_routes: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true
