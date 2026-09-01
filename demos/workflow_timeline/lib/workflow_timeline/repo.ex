defmodule WorkflowTimeline.Repo do
  use AshPostgres.Repo, otp_app: :workflow_timeline

  def installed_extensions do
    ["ash-functions", "uuid-ossp", "citext"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end
end
