defmodule AshWorkflowTest.SignalWaitWorkflow do
  @moduledoc """
  A workflow whose `:awaiting_payment` step has no action, transitions or
  timeout, so only a signal moves it, and whose `:customer_paid` handler
  selects records through the `customer` relationship.
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise
    signals AshWorkflowTest.OrderSignals

    step :awaiting_payment do
      on_signal :payment_settled do
        filter expr(id == ^signal(:order_id))
        transition_to :paid
      end

      on_signal :customer_paid do
        filter expr(customer.email == ^signal(:email))
        transition_to :paid
      end
    end

    step :paid, terminal: true
  end

  actions do
    defaults [:read, create: [:customer_id]]
  end

  attributes do
    uuid_v7_primary_key :id
  end

  relationships do
    belongs_to :customer, AshWorkflowTest.Customer, public?: true
  end
end
