# The Postgres suite needs a live repo and a real Oban instance; the ETS suite
# does not. Start them here so both can share one ExUnit run.
{:ok, _} =
  Supervisor.start_link(
    [
      AshWorkflowTest.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:ash_workflow, :ash_domains),
         Application.fetch_env!(:ash_workflow, Oban)
       )}
    ],
    strategy: :one_for_one,
    name: AshWorkflowTest.Supervisor
  )

Ecto.Adapters.SQL.Sandbox.mode(AshWorkflowTest.Repo, :manual)

ExUnit.start()

# Pre-initialize ETS tables for all test resources to avoid race conditions
# when async tests run before a table is lazily created.
for resource <- Ash.Domain.Info.resources(AshWorkflowTest.Domain) do
  Ash.DataLayer.Ets.TableManager.start(resource, nil)
end
