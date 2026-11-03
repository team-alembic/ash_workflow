defmodule AshWorkflow.OnSignalTest do
  @moduledoc """
  `on_signal` handlers on `AshWorkflowTest.OrderWorkflow` move or update the
  records their signal selects, and only while those records are in the step.
  """
  use ExUnit.Case, async: true

  import Ash.Signals.Test

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Signals.Registry
  alias AshWorkflow.Changes.RecordEvent
  alias AshWorkflowTest.AuthorizedOrderWorkflow
  alias AshWorkflowTest.Customer
  alias AshWorkflowTest.OrderSignals
  alias AshWorkflowTest.OrderWorkflow
  alias AshWorkflowTest.Payment
  alias AshWorkflowTest.SignalWaitWorkflow
  alias Spark.Dsl.Extension

  setup :capture_signals

  defp create(attrs \\ %{}) do
    record = OrderWorkflow.create!(attrs)
    flush_signals()
    record
  end

  defp flush_signals do
    receive do
      {:ash_signal_emitted, _, _, _, _} -> flush_signals()
    after
      0 -> :ok
    end
  end

  defp reload(record), do: Ash.get!(record.__struct__, record.id)

  defp unique, do: "batch-#{System.unique_integer([:positive])}"

  describe "a transition handler" do
    test "a payment settling moves the order and records the settlement time" do
      order = create()
      settled_at = DateTime.utc_now()

      Payment
      |> Ash.Changeset.for_create(:settle, %{order_id: order.id, settled_at: settled_at})
      |> Ash.create!()

      order = reload(order)
      assert order.state == :fulfilling
      assert order.paid_at == settled_at
    end

    test "emits the workflow's :order_changed triggered by :signal" do
      %{id: id} = order = create()

      react_to_signal(OrderSignals, :payment_settled, %{order_id: order.id}, inline?: true)

      assert_signal_emitted(OrderSignals, :order_changed, %{
        id: ^id,
        from_state: :awaiting_payment,
        to_state: :fulfilling,
        transition_name: :payment_settled,
        triggered_by: :signal
      })
    end

    test "fires the handler's nested emit" do
      %{id: id} = order = create()
      settled_at = DateTime.utc_now()

      react_to_signal(
        OrderSignals,
        :payment_settled,
        %{order_id: order.id, settled_at: settled_at},
        inline?: true
      )

      assert_signal_emitted(OrderSignals, :order_paid, %{id: ^id, paid_at: ^settled_at})
    end

    test "ignores a record that has already left the step" do
      order = create() |> Ash.update!(action: :mark_paid)
      flush_signals()

      assert :ok =
               react_to_signal(OrderSignals, :payment_settled, %{order_id: order.id},
                 inline?: true
               )

      assert reload(order).state == :fulfilling
      refute_signal_emitted(OrderSignals, :order_changed)
    end

    test "leaves records the signal does not select" do
      order = create()
      other = create()

      react_to_signal(OrderSignals, :payment_settled, %{order_id: order.id}, inline?: true)

      assert reload(other).state == :awaiting_payment
    end

    test "the step's manual transition still works" do
      order = create() |> Ash.update!(action: :mark_paid)

      assert order.state == :fulfilling
    end

    test "a filter on two signal fields moves every record it matches" do
      batch = unique()
      first = create(%{batch: batch, region: "north"})
      second = create(%{batch: batch, region: "north"})
      elsewhere = create(%{batch: batch, region: "south"})

      react_to_signal(OrderSignals, :batch_cancelled, %{batch: batch, region: "north"},
        inline?: true
      )

      assert reload(first).state == :cancelled
      assert reload(second).state == :cancelled
      assert reload(elsewhere).state == :awaiting_payment
    end

    test "a read_action of the resource selects the record, narrowed to the step" do
      reference = unique()
      order = create(%{reference: reference})
      paid = create(%{reference: reference}) |> Ash.update!(action: :mark_paid)

      react_to_signal(OrderSignals, :order_withdrawn, %{reference: reference}, inline?: true)

      assert reload(order).state == :cancelled
      assert reload(paid).state == :fulfilling
    end
  end

  describe "an action handler" do
    test "runs the action without changing state" do
      order = create()

      react_to_signal(
        OrderSignals,
        :address_changed,
        %{order_id: order.id, address: "1 Harbour St"},
        inline?: true
      )

      order = reload(order)
      assert order.state == :awaiting_payment
      assert order.address == "1 Harbour St"
      refute_signal_emitted(OrderSignals, :order_changed)
    end

    test "records the event without touching state_entered_at" do
      action = ResourceInfo.action(OrderWorkflow, :update_address)

      assert [{RecordEvent, opts}] =
               for(%{change: {RecordEvent, _} = change} <- action.changes, do: change)

      assert opts[:triggered_by] == :signal
      assert opts[:touch_state_entered_at] == false
    end
  end

  describe "a step whose only exits are on_signal" do
    defp create_waiting(customer) do
      record = Ash.create!(SignalWaitWorkflow, %{customer_id: customer.id})
      flush_signals()
      record
    end

    defp create_customer, do: Ash.create!(Customer, %{email: "#{unique()}@example.com"})

    test "a signal moves the record on" do
      record = create_waiting(create_customer())

      react_to_signal(OrderSignals, :payment_settled, %{order_id: record.id}, inline?: true)

      assert reload(record).state == :paid
    end

    test "a filter through a relationship moves only that customer's records" do
      customer = create_customer()
      record = create_waiting(customer)
      other = create_waiting(create_customer())

      react_to_signal(OrderSignals, :customer_paid, %{email: customer.email}, inline?: true)

      assert reload(record).state == :paid
      assert reload(other).state == :awaiting_payment
    end
  end

  describe "generated actions" do
    test "the read action takes one argument per signal field, typed from the signal" do
      read = ResourceInfo.action(OrderWorkflow, :__signal_awaiting_payment_batch_cancelled_read)

      assert read.type == :read

      assert [{:batch, Ash.Type.String, false}, {:region, Ash.Type.String, false}] =
               Enum.map(read.arguments, &{&1.name, Ash.Type.get_type(&1.type), &1.allow_nil?})
    end

    test "the read_action variant keeps the user's arguments" do
      read = ResourceInfo.action(OrderWorkflow, :__signal_awaiting_payment_order_withdrawn_read)

      assert Enum.map(read.arguments, & &1.name) == [:reference]
      assert ResourceInfo.action(OrderWorkflow, :by_reference).filter != read.filter
    end

    test "the transition action accepts the handler's inputs" do
      action = ResourceInfo.action(OrderWorkflow, :__signal_awaiting_payment_payment_settled)

      assert action.type == :update
      assert action.accept == [:paid_at]
    end

    test "a listener joins the read and transition actions" do
      listener =
        OrderWorkflow
        |> Extension.get_persisted(:signal_listeners)
        |> Enum.find(&(&1.name == :awaiting_payment_batch_cancelled))

      assert %{
               signal_module: OrderSignals,
               signal: :batch_cancelled,
               action: :__signal_awaiting_payment_batch_cancelled,
               read_action: :__signal_awaiting_payment_batch_cancelled_read,
               args: [batch: :batch, region: :region]
             } = listener

      assert listener in Registry.listeners(OrderSignals, :batch_cancelled)
    end

    test "AshWorkflow.Info lists the handlers" do
      assert [{:awaiting_payment, %{name: :payment_settled}} | _] =
               AshWorkflow.Info.on_signals(OrderWorkflow)

      assert length(AshWorkflow.Info.on_signals(OrderWorkflow, :awaiting_payment)) == 4
      assert AshWorkflow.Info.on_signals(OrderWorkflow, :fulfilling) == []
    end
  end

  describe "with Ash.Policy.Authorizer" do
    test "a policy authorizes the signal on the generated actions" do
      policy =
        AuthorizedOrderWorkflow
        |> Ash.Policy.Info.policies()
        |> Enum.find(fn policy ->
          Enum.any?(policy.policies, &(&1.check_module == Ash.Policy.Check.SignalIn))
        end)

      assert [{Ash.Policy.Check.Action, opts}] = policy.condition

      assert Enum.sort(opts[:action]) == [
               :__signal_awaiting_payment_payment_settled,
               :__signal_awaiting_payment_payment_settled_read
             ]
    end

    test "the listener may move the record, but a direct call may not" do
      order = Ash.create!(AuthorizedOrderWorkflow, %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(order, %{},
                 action: :__signal_awaiting_payment_payment_settled,
                 authorize?: true
               )

      assert :ok =
               react_to_signal(OrderSignals, :payment_settled, %{order_id: order.id},
                 inline?: true,
                 authorize?: true
               )

      assert reload(order).state == :fulfilling
    end
  end
end
