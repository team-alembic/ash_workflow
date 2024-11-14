defmodule AshWorkflowTest.Step1 do
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :update, :destroy]

    create :create do
      primary? true
      accept [:name]

      argument :something_else, :string

      change set_attribute(:something_else, arg(:something_else))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
        public? true
    end

    attribute :something_else, :string
  end
end
