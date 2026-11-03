defmodule AshWorkflow.SignalsTest do
  @moduledoc """
  `AshWorkflow.Changes.RecordEvent` emits the signals `AshWorkflowTest.SignalWorkflow`
  declares, with payloads built from the event and the record.
  """
  use ExUnit.Case, async: true

  import Ash.Signals.Test

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Changes.RecordEvent
  alias AshWorkflowTest.ApprovalWorkflow
  alias AshWorkflowTest.Signals
  alias AshWorkflowTest.SignalWorkflow

  setup :capture_signals

  defp create(name \\ "doc") do
    record = SignalWorkflow.create!(%{name: name})
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

  defp atomically(record, action) do
    SignalWorkflow
    |> Ash.Query.do_filter(id: record.id)
    |> Ash.bulk_update!(action, %{}, strategy: :atomic, return_errors?: true)

    Ash.get!(SignalWorkflow, record.id)
  end

  test "a create emits :state_changed from nil and enters the initial step" do
    %{id: id} = SignalWorkflow.create!(%{name: "doc"})

    assert_signal_emitted(Signals, :state_changed, %{
      id: ^id,
      from_state: nil,
      to_state: :review,
      triggered_by: :initial,
      occurred_at: %DateTime{}
    })

    assert_signal_emitted(Signals, :review_started, %{id: ^id, to_state: :review, name: "doc"})
    refute_signal_emitted(Signals, :review_finished)
  end

  test "approve emits the exit, the state change and its own signal" do
    %{id: id} = record = create("contract")

    Ash.update!(record, action: :approve)

    assert_signal_emitted(Signals, :state_changed, %{
      id: ^id,
      from_state: :review,
      to_state: :screening,
      transition_name: :approve,
      triggered_by: :manual
    })

    assert_signal_emitted(Signals, :review_finished, %{from_state: :review, to_state: :screening})

    assert_signal_emitted(Signals, :approved, %{
      id: ^id,
      name: "contract",
      verdict: "approved",
      transition_name: :approve
    })
  end

  test "reject emits the exit and the state change but not :approved" do
    record = create()

    Ash.update!(record, action: :reject)

    assert_signal_emitted(Signals, :state_changed, %{from_state: :review, to_state: :rejected})
    assert_signal_emitted(Signals, :review_finished, %{to_state: :rejected})
    refute_signal_emitted(Signals, :approved)
  end

  test "an automatic step emits :state_changed triggered by :automatic" do
    record = create() |> Ash.update!(action: :approve)
    flush_signals()

    Ash.update!(record, action: :screen)

    assert_signal_emitted(Signals, :state_changed, %{
      from_state: :screening,
      to_state: :done,
      triggered_by: :automatic
    })

    refute_signal_emitted(Signals, :review_finished)
  end

  test "the transition timeout emits :escalated, the exit and the state change" do
    record = create()

    Ash.update!(record, action: :__timeout_review_escalate)

    assert_signal_emitted(Signals, :escalated, %{triggered_by: :timeout})
    assert_signal_emitted(Signals, :review_finished, %{to_state: :escalated})

    assert_signal_emitted(Signals, :state_changed, %{
      from_state: :review,
      to_state: :escalated,
      triggered_by: :timeout
    })
  end

  test "the action timeout emits only :reminded" do
    %{id: id} = record = create()

    Ash.update!(record, action: :send_reminder)

    assert_signal_emitted(Signals, :reminded, %{id: ^id})
    refute_signal_emitted(Signals, :state_changed)
    refute_signal_emitted(Signals, :review_finished)
  end

  test "the every emits only :nudged" do
    %{id: id} = record = create()

    Ash.update!(record, action: :send_nudge)

    assert_signal_emitted(Signals, :nudged, %{id: ^id, occurred_at: %DateTime{}})
    refute_signal_emitted(Signals, :state_changed)
  end

  describe "on the atomic path" do
    # SignalWorkflow has no transition log, so these rely on `approve` having a
    # single `from` state, and on a non-state-changing action staying put.
    test "a transition knows the state it left" do
      record = create()

      assert atomically(record, :approve).state == :screening

      assert_signal_emitted(Signals, :state_changed, %{from_state: :review, to_state: :screening})
      assert_signal_emitted(Signals, :review_finished, %{from_state: :review})
      assert_signal_emitted(Signals, :approved, %{verdict: "approved"})
    end

    test "an action timeout still emits its signal" do
      %{id: id} = record = create()

      atomically(record, :send_reminder)

      assert_signal_emitted(Signals, :reminded, %{id: ^id})
    end
  end

  # ETS has no transactions, so the rollback itself is shown in
  # `AshWorkflowTest.Postgres.SignalRollbackTest`.
  test "a failing listener fails the transition" do
    record = create("refuse")

    assert {:error, _error} = Ash.update(record, action: :approve)
  end

  test "a resource with no signals module plans and emits nothing" do
    action = ResourceInfo.action(ApprovalWorkflow, :approve)

    for %{change: {RecordEvent, opts}} <- action.changes do
      refute Keyword.has_key?(opts, :emits)
    end

    {:ok, record} = ApprovalWorkflow.create(%{title: "plain"})
    Ash.update!(record, action: :approve)

    refute_signal_emitted(Signals, :state_changed)
  end
end
