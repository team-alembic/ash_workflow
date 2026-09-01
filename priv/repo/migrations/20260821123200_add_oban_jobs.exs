defmodule AshWorkflowTest.Repo.Migrations.AddObanJobs do
  @moduledoc "Oban's job table, needed so the integration tests can run real triggers."
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
