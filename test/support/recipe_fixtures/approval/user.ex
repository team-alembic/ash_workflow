defmodule AshWorkflowTest.RecipeFixtures.Approval.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Approval.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]

    create :create do
      accept [:name, :role]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :role, :atom, public?: true
  end
end
