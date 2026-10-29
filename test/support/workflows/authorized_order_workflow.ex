defmodule AshWorkflowTest.AuthorizedOrderWorkflow do
  @moduledoc """
  An `on_signal` on a resource with `Ash.Policy.Authorizer`, where only the
  `:payment_settled` listener may run the generated actions.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise
    signals AshWorkflowTest.OrderSignals

    step :awaiting_payment do
      transition :mark_paid, to: :fulfilling

      on_signal :payment_settled do
        filter expr(id == ^signal(:order_id))
        transition_to :fulfilling
      end
    end

    step :fulfilling, terminal: true
  end

  actions do
    defaults [:read, create: []]
  end

  attributes do
    uuid_v7_primary_key :id
  end
end
