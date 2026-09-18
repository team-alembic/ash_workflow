defmodule OrderFulfilment.Order do
  @moduledoc """
  An order moving through payment, stock reservation, packing and shipping,
  where each stage is background work that can fail.

      placed ──▶ charging_card ──▶ reserving_stock ──▶ packing ──▶ shipping ──▶ shipped
                      │                  │                            │
                      │                  ╰──▶ backordered ──(restocked)──╮
                      │                            │                     │
                      │                            ╰─(cancel)──▶ cancelled
                      │
                      ╰──▶ payment_failed ──(retry_payment)──▶ charging_card
                                 │
                                 ╰─ 3 days ──▶ cancelled

  This is the demo for **error handling in a long automatic chain**. Every
  automatic step declares `on_error`, so a failure lands the order in a state
  that names the problem rather than leaving it stuck mid-flight. Two of those
  error states are recoverable, and their recovery transitions loop *backwards*
  into the chain — `retry_payment` returns to `:charging_card`, `restocked`
  returns to `:reserving_stock`.
  """

  use Ash.Resource,
    domain: OrderFulfilment.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "orders"
    repo OrderFulfilment.Repo
  end

  workflow do
    # Fulfilment is time-sensitive, so this one does poll every minute.
    queue :fulfilment
    check_interval "* * * * *"

    step :charging_card do
      action :charge_card
      on_success :reserving_stock
      on_error :payment_failed
    end

    step :reserving_stock do
      action :reserve_stock
      on_success :packing
      on_error :backordered
    end

    step :packing do
      action :pack
      on_success :shipping
      on_error :packing_failed
    end

    step :shipping do
      action :ship
      on_success :shipped
      on_error :shipping_failed
    end

    # Recoverable failure: the customer fixes their card and we re-enter the
    # chain at the point that failed.
    step :payment_failed do
      transition :retry_payment, to: :charging_card
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]

      timeout :abandon, fire_after: {3, :days}, transition_to: :cancelled
    end

    # Recoverable failure: stock arrives and we re-enter the chain.
    step :backordered do
      transition :restocked, to: :reserving_stock
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]

      every :chase_supplier do
        interval {2, :days}
        action :chase_supplier
      end
    end

    # Unrecoverable without a human: warehouse staff have to look at it.
    step :packing_failed do
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]
    end

    step :shipping_failed do
      transition :retry_shipping, to: :shipping
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]
    end

    step :shipped, terminal: true
    step :cancelled, terminal: true
  end

  code_interface do
    define :place, action: :place
  end

  actions do
    defaults [:read]

    create :place do
      accept [:reference, :total_cents, :card_valid?, :stock_available?, :address_valid?]
    end

    update :charge_card do
      accept []
      require_atomic? false
      change OrderFulfilment.Order.ChargeCard
    end

    update :reserve_stock do
      accept []
      require_atomic? false
      change OrderFulfilment.Order.ReserveStock
    end

    update :pack do
      accept []
      require_atomic? false
      change OrderFulfilment.Order.Pack
    end

    update :ship do
      accept []
      require_atomic? false
      change OrderFulfilment.Order.Ship
    end

    update :chase_supplier do
      accept []
      require_atomic? false
      change OrderFulfilment.Order.ChaseSupplier
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :reference, :string, allow_nil?: false, public?: true
    attribute :total_cents, :integer, allow_nil?: false, public?: true

    # Stand-ins for the outside world: flipping these is how the tests steer a
    # given order down the success or failure branch of each step.
    attribute :card_valid?, :boolean, allow_nil?: false, default: true, public?: true
    attribute :stock_available?, :boolean, allow_nil?: false, default: true, public?: true
    attribute :address_valid?, :boolean, allow_nil?: false, default: true, public?: true

    attribute :charge_reference, :string, public?: true
    attribute :tracking_number, :string, public?: true
    attribute :payment_attempts, :integer, allow_nil?: false, default: 0, public?: true
    attribute :supplier_chases, :integer, allow_nil?: false, default: 0, public?: true
    attribute :cancellation_reason, :string, public?: true
  end
end
