defmodule AshWorkflowDemo.Repo do
  use AshPostgres.Repo, otp_app: :ash_workflow_demo

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end

  # The running app holds the connection pool, so the database itself can't be dropped. Truncating every table has the same effect.
  def truncate_all do
    %{rows: rows} =
      query!("""
      SELECT quote_ident(tablename) FROM pg_tables
      WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
      """)

    tables = Enum.map_join(rows, ", ", fn [table] -> ~s("public".#{table}) end)
    query!("TRUNCATE #{tables} RESTART IDENTITY CASCADE")
    :ok
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end
end
