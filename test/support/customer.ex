defmodule AshWorkflowTest.Customer do
  @moduledoc """
  The customer an `AshWorkflowTest.SignalWaitWorkflow` record belongs to, so an
  `on_signal` filter can follow the relationship.
  """
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:email]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true
  end
end
