defmodule AshWorkflowTest.RecipeFixtures.Approval.LedgerLine do
  @moduledoc false
  use Ash.Resource,
    domain: AshWorkflowTest.RecipeFixtures.Approval.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    attribute :ledger, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :line, :integer, primary_key?: true, allow_nil?: false, public?: true
  end
end
