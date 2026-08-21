defmodule Example.Repo do
  @moduledoc """
  Stand-in repo so the example resources are complete, compilable code.

  In your own application this is your app's own `AshPostgres.Repo`.
  """
  use AshPostgres.Repo, otp_app: :ash_workflow

  def installed_extensions, do: ["ash-functions", "uuid-ossp"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
