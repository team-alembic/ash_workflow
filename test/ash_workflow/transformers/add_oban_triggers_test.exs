defmodule AshWorkflow.Transformers.AddObanTriggersTest do
  use ExUnit.Case

  describe "automatic step triggers" do
    test "generates trigger for automatic step" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.Workflow)

      assert Enum.any?(triggers, fn t ->
               t.name == :process_application and t.action == :process_application
             end)
    end

    test "trigger has explicit worker and scheduler module names" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.Workflow)
      trigger = Enum.find(triggers, &(&1.name == :process_application))

      assert trigger.worker_module_name ==
               AshWorkflowTest.Workflow.AshWorkflow.Workers.ProcessApplication

      assert trigger.scheduler_module_name ==
               AshWorkflowTest.Workflow.AshWorkflow.Schedulers.ProcessApplication
    end

    test "linear workflow generates trigger for its automatic step" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.LinearWorkflow)

      assert Enum.any?(triggers, fn t ->
               t.name == :process and t.action == :do_processing
             end)
    end

    test "full pipeline generates triggers for both automatic steps" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.FullPipeline)
      trigger_names = Enum.map(triggers, & &1.name) |> MapSet.new()

      assert :intake in trigger_names
      assert :process in trigger_names
    end
  end

  describe "manual-only workflows" do
    test "approval workflow has no triggers" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.ApprovalWorkflow)
      assert triggers == []
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
