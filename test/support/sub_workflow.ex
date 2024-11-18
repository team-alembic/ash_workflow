defmodule AshWorkflowTest.SubWorkflow do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  state_machine do
    initial_states([:step1])
  end

  workflow do
    action_step(:create_step2_resource, :create, AshWorkflowTest.Step2)

    action_step :update_step2_resource, :update, AshWorkflowTest.Step2 do
      initial(result(:create_step2_resource))
    end
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
