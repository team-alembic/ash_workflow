defmodule AshWorkflow.Calculations.PendingDeadlinesTest do
  @moduledoc """
  `pending_deadlines` answers "what is scheduled to happen to this record, and
  when" — derived on read from the DSL and the record's own timestamps, with
  nothing stored.
  """
  use ExUnit.Case, async: true

  defp deadlines(record) do
    record
    |> Ash.load!(:pending_deadlines)
    |> Map.fetch!(:pending_deadlines)
  end

  describe "a record in a step with timeouts" do
    setup do
      {:ok, record} = AshWorkflowTest.TimeoutWorkflow.create(%{title: "test"})
      assert record.state == :waiting

      %{record: record}
    end

    test "lists every timeout on the current step", %{record: record} do
      assert [reminder, escalation] = deadlines(record)

      assert reminder.name == :reminder
      assert escalation.name == :escalation
    end

    test "orders them soonest first", %{record: record} do
      assert [%{name: :reminder}, %{name: :escalation}] = deadlines(record)
    end

    test "computes due_at as field + after", %{record: record} do
      assert [reminder, escalation] = deadlines(record)

      assert DateTime.diff(reminder.due_at, record.state_entered_at, :day) == 2
      assert DateTime.diff(escalation.due_at, record.state_entered_at, :day) == 7
    end

    test "distinguishes action timeouts from transition timeouts", %{record: record} do
      assert [reminder, escalation] = deadlines(record)

      assert reminder.kind == :action
      assert reminder.target == nil

      assert escalation.kind == :transition
      assert escalation.target == :escalated
    end
  end

  describe "a record with no deadlines ahead of it" do
    test "is empty in a terminal step" do
      {:ok, record} = AshWorkflowTest.TimeoutWorkflow.create(%{title: "test"})
      {:ok, record} = AshWorkflowTest.TimeoutWorkflow.resolve(record)

      assert record.state == :resolved
      assert deadlines(record) == []
    end

    test "is empty in a step that declares none" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      assert deadlines(record) == []
    end
  end

  describe "custom timeout fields" do
    test "measure from that field rather than state_entered_at" do
      last_session = ~U[2026-01-01 00:00:00.000000Z]

      {:ok, record} =
        AshWorkflowTest.FieldTimeoutWorkflow.create(%{
          title: "test",
          last_session_date: last_session
        })

      assert [deadline] = deadlines(record)
      assert deadline.due_at == DateTime.add(last_session, 3, :day)
    end

    test "are omitted when the field is nil, having no derivable deadline" do
      {:ok, record} =
        AshWorkflowTest.FieldTimeoutWorkflow.create(%{title: "test", last_session_date: nil})

      assert deadlines(record) == []
    end
  end
end
