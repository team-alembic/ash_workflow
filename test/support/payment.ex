defmodule AshWorkflowTest.Payment do
  @moduledoc """
  Emits `:payment_settled` from its create action, so a test can move an
  `AshWorkflowTest.OrderWorkflow` record with a real emitter.
  """
  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]

    create :settle do
      accept [:order_id, :settled_at]

      emit AshWorkflowTest.OrderSignals, :payment_settled, fields: [:order_id, :settled_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :order_id, :uuid, allow_nil?: false, public?: true
    attribute :settled_at, :utc_datetime_usec, public?: true
  end
end
