defmodule AshWorkflow.Resources.Step do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :name, :atom do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :resource, :atom do
      allow_nil? false
      public? true
    end

    attribute :action, :atom do
      allow_nil? false
      public? true
    end

    attribute :params, {:array, :struct} do
      allow_nil? false
      constraints items: [instance_of: AshWorkflow.Resources.Param]
      public? true
    end
  end
end
