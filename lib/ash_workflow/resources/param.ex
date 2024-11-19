defmodule AshWorkflow.Resources.Param do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :name, :atom do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
    end

    attribute :required, :boolean do
      allow_nil? false
      public? true
    end
  end
end
