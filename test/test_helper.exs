# The Postgres suite needs a live repo and a real Oban instance; the ETS suite
# does not. Start them here so both can share one ExUnit run. The recipe
# fixtures are compiled again under a new name by each test, so their
# originals never run Oban jobs.
oban_domains =
  Application.fetch_env!(:ash_workflow, :ash_domains) --
    Application.fetch_env!(:ash_workflow, :recipe_fixture_domains)

{:ok, _} =
  Supervisor.start_link(
    [
      AshWorkflowTest.Repo,
      {Oban, AshOban.config(oban_domains, Application.fetch_env!(:ash_workflow, Oban))}
    ],
    strategy: :one_for_one,
    name: AshWorkflowTest.Supervisor
  )

Ecto.Adapters.SQL.Sandbox.mode(AshWorkflowTest.Repo, :manual)

ExUnit.start()

# The tests tagged `:dot` run Graphviz's `dot`. When `dot` is not on the
# PATH, the helper excludes them. CI installs Graphviz, so CI runs them.
if AshWorkflow.Charts.Dot.executable() == nil do
  ExUnit.configure(exclude: [:dot | Keyword.get(ExUnit.configuration(), :exclude, [])])

  IO.puts(
    "dot is not on the PATH, so the tests tagged :dot do not run. " <>
      "Install Graphviz to run them."
  )
end

# Pre-initialize ETS tables for all test resources to avoid race conditions
# when async tests run before a table is lazily created.
for resource <- Ash.Domain.Info.resources(AshWorkflowTest.Domain) do
  Ash.DataLayer.Ets.TableManager.start(resource, nil)
end
