defmodule AshWorkflowTest.RecipeFixtures.Invitation.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Invitation.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]

    create :create do
      accept [:email]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
  end
end
