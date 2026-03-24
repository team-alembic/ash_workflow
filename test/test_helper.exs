ExUnit.start()

# Pre-initialize ETS tables for all test resources to avoid race conditions
# when async tests run before a table is lazily created.
for resource <- Ash.Domain.Info.resources(AshWorkflowTest.Domain) do
  Ash.DataLayer.Ets.TableManager.start(resource, nil)
end
