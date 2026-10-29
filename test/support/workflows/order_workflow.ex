defmodule AshWorkflowTest.OrderWorkflow do
  @moduledoc """
  A workflow whose `:awaiting_payment` step can be left by a person, by a
  signal or by a timeout, and whose signals from `AshWorkflowTest.OrderSignals`
  select records by id, by two fields, or through a read action of its own.

      awaiting_payment ──(mark_paid | :payment_settled)──▶ fulfilling
                       ├─(:batch_cancelled | :order_withdrawn)──▶ cancelled
                       ├─ after 3 days ──▶ cancelled
                       └─ :address_changed ──▶ (update_address)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise
    signals AshWorkflowTest.OrderSignals

    emit :order_changed

    step :awaiting_payment do
      transition :mark_paid, to: :fulfilling

      on_signal :payment_settled do
        filter expr(id == ^signal(:order_id))
        transition_to :fulfilling
        inputs paid_at: :settled_at
        emit :order_paid, fields: [:paid_at]
      end

      on_signal :address_changed do
        filter expr(id == ^signal(:order_id))
        action :update_address
        inputs [:address]
      end

      on_signal :batch_cancelled do
        filter expr(batch == ^signal(:batch) and region == ^signal(:region))
        transition_to :cancelled
      end

      on_signal :order_withdrawn do
        read_action :by_reference
        transition_to :cancelled
      end

      timeout :expire do
        fire_after {3, :days}
        transition_to :cancelled
      end
    end

    step :fulfilling, terminal: true
    step :cancelled, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:reference, :batch, :region]
    end

    read :by_reference do
      argument :reference, :string, allow_nil?: false
      filter expr(reference == ^arg(:reference))
    end

    update :update_address do
      accept [:address]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :reference, :string, public?: true
    attribute :batch, :string, public?: true
    attribute :region, :string, public?: true
    attribute :address, :string, public?: true
    attribute :paid_at, :utc_datetime_usec, public?: true
  end
end
