defmodule AshWorkflowTest.RecipeFixtures.Approval.Receipt do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Approval.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:id, :merchant]]
  end

  attributes do
    # ETS generates no keys, so the caller supplies one.
    integer_primary_key :id, writable?: true, generated?: false
    attribute :merchant, :string, public?: true
  end
end
