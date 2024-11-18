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

    switch :update_or_destroy do
      on result(:create_step2_resource, [:name])

      matches? &(&1 == "update") do
        action_step :update_step2_resource, :update, AshWorkflowTest.Step2 do
          initial(result(:create_step2_resource))
        end
      end

      default do
        action_step :destroy_step2_resource, :destroy, AshWorkflowTest.Step2 do
          initial(result(:create_step2_resource))
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
