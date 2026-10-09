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

# The tests tagged `:d2` run `d2`. This helper never downloads it, so the
# suite runs with no network access. When `d2` is not installed, the helper
# excludes those tests. CI installs `d2` first, so CI runs them.
if not AshWorkflow.Charts.D2.Binary.installed?() do
  ExUnit.configure(exclude: [:d2 | Keyword.get(ExUnit.configuration(), :exclude, [])])

  IO.puts(
    "d2 is not installed, so the tests tagged :d2 do not run. " <>
      "Run `mix ash_workflow.d2.install` to run them."
  )
end

# The tests tagged `:dot` run Graphviz's `dot`. This library does not download
# it, so when `dot` is not on the PATH, the helper excludes those tests. CI
# installs Graphviz first, so CI runs them.
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
