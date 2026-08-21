defmodule AshWorkflowTest.Repo do
  @moduledoc """
  Test repo for the Postgres integration suite.

  The bulk of the suite runs against ETS, which is enough to assert what the
  transformers generate. These tests exercise the parts that only exist once a
  real database and a real Oban are involved: the generated `state_entered_at`
  attribute round-tripping through a migration, and Oban actually picking up
  and executing the triggers AshWorkflow schedules.
  """
  use AshPostgres.Repo, otp_app: :ash_workflow

  def installed_extensions, do: ["ash-functions", "uuid-ossp", "citext"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
