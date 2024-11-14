defmodule AshWorkflowTest.SubWorkflow do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    action_step(:create_step2_resource, :create, AshWorkflowTest.Step2)
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
