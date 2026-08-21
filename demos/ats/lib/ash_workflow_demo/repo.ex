defmodule AshWorkflowDemo.Repo do
  use AshPostgres.Repo, otp_app: :ash_workflow_demo

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end
end
