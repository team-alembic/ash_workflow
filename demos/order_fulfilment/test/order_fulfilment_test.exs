defmodule OrderFulfilment.OrderTest do
  @moduledoc """
  Exercises a four-stage automatic chain where every stage can fail, and where
  two of the failure states recover by looping backwards into the chain.
  """
  use OrderFulfilment.DataCase

  alias OrderFulfilment.Order

  defp place(attrs \\ %{}) do
    Order.place!(Map.merge(%{reference: "ORD-1", total_cents: 4900}, attrs))
  end

  defp reload(order), do: Ash.get!(Order, order.id, authorize?: false)

  # Drives the chain until it settles: each drain advances one automatic step,
  # so a four-step chain needs several passes.
  defp run_to_rest(order, passes \\ 6) do
    Enum.each(1..passes, fn _ -> run_workflow_triggers(Order) end)
    reload(order)
  end

  describe "the happy path" do
    test "an order with everything in order ships" do
      order = place() |> run_to_rest()

      assert order.state == :shipped
      assert order.charge_reference
      assert order.tracking_number
      assert order.payment_attempts == 1
    end

    test "an order starts in the first automatic step" do
      assert place().state == :charging_card
    end
  end

  describe "error routing" do
    test "a declined card lands in payment_failed, not stuck in charging_card" do
      order = place(%{card_valid?: false}) |> run_to_rest()

      assert order.state == :payment_failed
      refute order.charge_reference

      # The failed action ran in a transaction, so its own writes — including
      # the attempt counter it bumped — rolled back with it. Only the state
      # change made by the on_error handler survives.
      assert order.payment_attempts == 0
    end

    test "no stock lands in backordered, after payment has succeeded" do
      order = place(%{stock_available?: false}) |> run_to_rest()

      assert order.state == :backordered
      assert order.charge_reference, "the card is charged before stock is reserved"
    end

    test "a bad address lands in shipping_failed, after packing" do
      order = place(%{address_valid?: false}) |> run_to_rest()

      assert order.state == :shipping_failed
      refute order.tracking_number
    end
  end

  describe "recovering by looping back into the chain" do
    test "retry_payment re-runs the payment step and continues to shipped" do
      order = place(%{card_valid?: false}) |> run_to_rest()
      assert order.state == :payment_failed

      # The customer fixes their card, then the same step runs again.
      fixed = set_card_valid(order)
      Order.retry_payment!(fixed, authorize?: false)

      order = run_to_rest(order)

      assert order.state == :shipped
      assert order.charge_reference, "the payment step really re-ran and succeeded"
      assert order.payment_attempts == 1
    end

    test "restocked re-runs stock reservation and continues to shipped" do
      order = place(%{stock_available?: false}) |> run_to_rest()
      assert order.state == :backordered

      restocked = set_stock_available(order)
      Order.restocked!(restocked, authorize?: false)

      assert run_to_rest(order).state == :shipped
    end

    test "retry_shipping re-runs only the shipping step" do
      order = place(%{address_valid?: false}) |> run_to_rest()
      assert order.state == :shipping_failed

      corrected = set_address_valid(order)
      Order.retry_shipping!(corrected, authorize?: false)

      order = run_to_rest(order)

      assert order.state == :shipped
      assert order.payment_attempts == 1, "recovering shipping must not re-charge the card"
    end
  end

  describe "cancelling" do
    test "the same :cancel transition works from every recoverable failure" do
      for {attrs, expected_state} <- [
            {%{card_valid?: false}, :payment_failed},
            {%{stock_available?: false}, :backordered},
            {%{address_valid?: false}, :shipping_failed}
          ] do
        order = place(attrs) |> run_to_rest()
        assert order.state == expected_state

        cancelled =
          Order.cancel!(order, %{cancellation_reason: "customer changed their mind"},
            authorize?: false
          )

        assert cancelled.state == :cancelled
        assert cancelled.cancellation_reason == "customer changed their mind"
      end
    end

    test "a shipped order cannot be cancelled" do
      order = place() |> run_to_rest()
      assert order.state == :shipped

      assert {:error, _} =
               Order.cancel(order, %{cancellation_reason: "too late"}, authorize?: false)
    end
  end

  describe "timeouts on failure states" do
    test "an unresolved payment failure is abandoned after three days" do
      order = place(%{card_valid?: false}) |> run_to_rest()
      assert order.state == :payment_failed

      age_by(order, 4, :day)
      run_workflow_triggers(Order)

      assert reload(order).state == :cancelled
    end

    test "a backorder chases the supplier repeatedly without leaving the state" do
      order = place(%{stock_available?: false}) |> run_to_rest()
      assert order.state == :backordered

      age_by(order, 3, :day)
      run_workflow_triggers(Order)
      assert reload(order).supplier_chases == 1
      assert reload(order).state == :backordered

      age_by(order, 3, :day)
      run_workflow_triggers(Order)
      assert reload(order).supplier_chases == 2
    end
  end

  defp set_card_valid(order), do: force(order, :card_valid?, true)
  defp set_stock_available(order), do: force(order, :stock_available?, true)
  defp set_address_valid(order), do: force(order, :address_valid?, true)

  # The outside world changing is not part of the workflow, so these write
  # directly rather than going through an action.
  defp force(order, field, value) do
    import Ecto.Query

    {1, _} =
      OrderFulfilment.Repo.update_all(
        from(o in "orders", where: o.id == type(^order.id, :binary_id)),
        set: [{field, value}]
      )

    Map.put(order, field, value)
  end
end
