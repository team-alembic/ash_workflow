defmodule AshWorkflowTest.NoExprErrorRepo do
  @moduledoc """
  Test repo that shares `AshWorkflowTest.Repo`'s database but cannot compile
  `error/2` expressions, so an action that needs one cannot run atomically.
  """
  use AshPostgres.Repo, otp_app: :ash_workflow

  def installed_extensions, do: ["ash-functions", "uuid-ossp", "citext"]

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}

  def disable_expr_error?, do: true
end
