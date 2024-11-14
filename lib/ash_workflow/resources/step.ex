defmodule AshWorkflow.Resources.Step do
  use Ash.Resource,
    data_layer: :embedded

  actions do
    create :from_step do
      argument :step, :struct do
        allow_nil? false
        constraints instance_of: AshWorkflow.Entities.Step
      end

      change {__MODULE__.FromStep, []}
    end
  end

  attributes do
    attribute :name, :atom do
      primary_key? true
      allow_nil? false
    end

    attribute :resource, :atom do
      allow_nil? false
    end

    attribute :action, :atom do
      allow_nil? false
    end

    attribute :params, {:array, :struct} do
      allow_nil? false
      constraints items: [instance_of: AshWorkflow.Resources.Param]
    end
  end
end
