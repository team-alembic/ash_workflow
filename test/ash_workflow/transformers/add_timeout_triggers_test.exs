defmodule AshWorkflow.Transformers.AddTimeoutTriggersTest do
  use ExUnit.Case

  alias AshWorkflowTest.TimeoutWorkflow
  alias AshWorkflowTest.Workflow

  defp trigger(resource, name) do
    resource
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == name))
  end

  defp matching_records(resource, trigger) do
    resource
    |> Ash.Query.do_filter(trigger.where)
    |> Ash.read!()
    |> Map.get(:results)
  end

  defp create_with_backdated_state_entered_at(resource, attrs, days_ago) do
    resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.Changeset.force_change_attribute(
      :state_entered_at,
      DateTime.add(DateTime.utc_now(), -days_ago, :day)
    )
    |> Ash.create!()
  end

  describe "action timeout triggers" do
    test "matches records past the deadline" do
      # Reminder timeout is fire_after: {2, :days} — backdate to 3 days ago
      workflow = create_with_backdated_state_entered_at(TimeoutWorkflow, %{title: "overdue"}, 3)

      trigger = trigger(TimeoutWorkflow, :__timeout_trigger_waiting_reminder)
      matches = matching_records(TimeoutWorkflow, trigger)

      assert workflow.id in Enum.map(matches, & &1.id)
    end

    test "does not match records within the deadline" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "fresh"})

      trigger = trigger(TimeoutWorkflow, :__timeout_trigger_waiting_reminder)
      matches = matching_records(TimeoutWorkflow, trigger)

      refute workflow.id in Enum.map(matches, & &1.id)
    end
  end

  describe "transition timeout triggers" do
    test "matches records past the deadline" do
      # Escalation timeout is fire_after: {7, :days} — backdate to 8 days ago
      workflow = create_with_backdated_state_entered_at(TimeoutWorkflow, %{title: "stale"}, 8)

      trigger = trigger(TimeoutWorkflow, :__timeout_trigger_waiting_escalation)
      matches = matching_records(TimeoutWorkflow, trigger)

      assert workflow.id in Enum.map(matches, & &1.id)
    end

    test "the timeout action transitions state" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "escalate me"})
      {:ok, escalated} = Ash.update(workflow, action: :__timeout_waiting_escalation)
      assert escalated.state == :escalated
    end
  end

  describe "timeout triggers have explicit module names" do
    test "worker and scheduler modules follow naming convention" do
      trigger = trigger(TimeoutWorkflow, :__timeout_trigger_waiting_reminder)

      # Scoped by step, so two steps can each declare a `:reminder` timeout.
      assert trigger.worker_module_name ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Workers.Timeouts.Waiting.Reminder

      assert trigger.scheduler_module_name ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Schedulers.Timeouts.Waiting.Reminder
    end
  end

  describe "timeout triggers coexist with step triggers" do
    test "automatic step trigger and timeout triggers are all present" do
      triggers = AshOban.Info.oban_triggers(Workflow)
      trigger_names = Enum.map(triggers, & &1.name) |> MapSet.new()

      assert :process_application in trigger_names
      assert :__timeout_trigger_review_reminder in trigger_names
      assert :__timeout_trigger_review_escalation in trigger_names
    end
  end
end
