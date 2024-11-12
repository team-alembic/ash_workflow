defmodule AshWorkflowTest.Workflow do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  attributes do
    uuid_v7_primary_key :id
  end

  workflow do
  end
end
