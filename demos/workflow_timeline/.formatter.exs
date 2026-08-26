[
  import_deps: [:ecto, :ecto_sql, :phoenix, :ash, :ash_postgres, :ash_oban, :ash_workflow],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
