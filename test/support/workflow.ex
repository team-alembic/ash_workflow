defmodule AshWorkflowTest.Workflow do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    step(:create_step1_resource, :create, AshWorkflowTest.Step1)

    workflow(:sub_workflow, AshWorkflowTest.SubWorkflow)
  end

  actions do
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
