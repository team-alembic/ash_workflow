defmodule AshWorkflowTest.OrderSignals do
  @moduledoc """
  Signals that `AshWorkflowTest.OrderWorkflow` receives through `on_signal`,
  and the ones it emits back.
  """
  use Ash.Signals

  signals do
    signal :payment_settled do
      argument :order_id, :uuid, allow_nil?: false
      argument :settled_at, :utc_datetime_usec
    end

    signal :address_changed do
      argument :order_id, :uuid, allow_nil?: false
      argument :address, :string
    end

    signal :batch_cancelled do
      argument :batch, :string, allow_nil?: false
      argument :region, :string, allow_nil?: false
    end

    signal :order_withdrawn do
      argument :reference, :string, allow_nil?: false
    end

    signal :customer_paid do
      argument :email, :string, allow_nil?: false
    end

    signal :order_changed do
      argument :id, :uuid, allow_nil?: false
      argument :from_state, :atom
      argument :to_state, :atom, allow_nil?: false
      argument :transition_name, :atom
      argument :triggered_by, :atom, allow_nil?: false
    end

    signal :order_paid do
      argument :id, :uuid, allow_nil?: false
      argument :paid_at, :utc_datetime_usec
    end
  end
end
