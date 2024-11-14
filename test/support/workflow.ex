defmodule AshWorkflowTest.Workflow do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    action_step(:create_step1_resource, :create, AshWorkflowTest.Step1)

    workflow_step(:sub_workflow, AshWorkflowTest.SubWorkflow)
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
