defmodule AshWorkflow.Transformers.AddObanTriggersTest do
  use ExUnit.Case

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

  describe "automatic step triggers" do
    test "matches records in the step's state" do
      {:ok, workflow} =
        AshWorkflowTest.LinearWorkflow.create(%{title: "test"})

      trigger = trigger(AshWorkflowTest.LinearWorkflow, :process)
      matches = matching_records(AshWorkflowTest.LinearWorkflow, trigger)

      assert workflow.id in Enum.map(matches, & &1.id)
    end

    test "does not match records that have left the step's state" do
      {:ok, workflow} = AshWorkflowTest.LinearWorkflow.create(%{title: "test"})
      {:ok, workflow} = Ash.update(workflow, action: :do_processing)
      assert workflow.state == :complete

      trigger = trigger(AshWorkflowTest.LinearWorkflow, :process)
      matches = matching_records(AshWorkflowTest.LinearWorkflow, trigger)

      refute workflow.id in Enum.map(matches, & &1.id)
    end

    test "trigger has explicit worker and scheduler module names" do
      trigger = trigger(AshWorkflowTest.Workflow, :process_application)

      assert trigger.worker_module_name ==
               AshWorkflowTest.Workflow.AshWorkflow.Workers.ProcessApplication

      assert trigger.scheduler_module_name ==
               AshWorkflowTest.Workflow.AshWorkflow.Schedulers.ProcessApplication
    end
  end

  describe "manual-only workflows" do
    test "approval workflow has no triggers" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.ApprovalWorkflow)
      assert triggers == []
    end
  end

  describe "timeout and every trigger behavior" do
    test "non-repeating action timeout generates trigger_once? true" do
      trigger = trigger(AshWorkflowTest.TimeoutWorkflow, :__timeout_trigger_waiting_reminder)
      assert trigger.trigger_once? == true
    end

    test "an every does not set trigger_once?" do
      trigger =
        trigger(AshWorkflowTest.RepeatingTimeoutWorkflow, :__every_trigger_waiting_follow_up)

      assert trigger.trigger_once? == false
    end

    test "an every injects a RecordEvent that resets state_entered_at" do
      action =
        Ash.Resource.Info.action(AshWorkflowTest.RepeatingTimeoutWorkflow, :send_follow_up)

      assert Enum.any?(action.changes, fn
               %{change: {AshWorkflow.Changes.RecordEvent, opts}} ->
                 opts[:triggered_by] == :timeout

               _ ->
                 false
             end)
    end

    test "transition timeouts are not affected by an every elsewhere on the resource" do
      trigger = trigger(AshWorkflowTest.TimeoutWorkflow, :__timeout_trigger_waiting_escalation)
      assert trigger.trigger_once? == false
    end
  end

  describe "configurable queue" do
    test "default queue is :workflow" do
      trigger = trigger(AshWorkflowTest.LinearWorkflow, :process)
      assert trigger.queue == :workflow
    end

    test "custom queue is applied to step triggers" do
      trigger = trigger(AshWorkflowTest.CustomQueueWorkflow, :process)
      assert trigger.queue == :hiring_pipeline
    end

    test "custom queue is applied to timeout triggers" do
      trigger = trigger(AshWorkflowTest.CustomQueueWorkflow, :__timeout_trigger_review_reminder)
      assert trigger.queue == :hiring_pipeline
    end
  end

  describe "read action generation" do
    test "generates primary read action for resources with automatic steps" do
      action = Ash.Resource.Info.primary_action(AshWorkflowTest.LinearWorkflow, :read)
      assert action != nil
      assert action.name == :read
    end
  end
end
