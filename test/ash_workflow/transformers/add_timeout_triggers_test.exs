defmodule AshWorkflow.Transformers.AddTimeoutTriggersTest do
  use ExUnit.Case

  describe "timeout triggers" do
    test "generates trigger for action timeout" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.TimeoutWorkflow)

      assert Enum.any?(triggers, fn t ->
               t.name == :__timeout_trigger_reminder and t.action == :send_reminder
             end)
    end

    test "generates trigger for transition timeout" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.TimeoutWorkflow)

      assert Enum.any?(triggers, fn t ->
               t.name == :__timeout_trigger_escalation and t.action == :__timeout_escalation
             end)
    end

    test "timeout triggers have explicit module names" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.TimeoutWorkflow)
      trigger = Enum.find(triggers, &(&1.name == :__timeout_trigger_reminder))

      assert trigger.worker_module_name ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Workers.Timeouts.Reminder

      assert trigger.scheduler_module_name ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Schedulers.Timeouts.Reminder
    end

    test "main workflow generates timeout triggers alongside step triggers" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.Workflow)
      trigger_names = Enum.map(triggers, & &1.name) |> MapSet.new()

      # Automatic step trigger
      assert :process_application in trigger_names
      # Timeout triggers
      assert :__timeout_trigger_reminder in trigger_names
      assert :__timeout_trigger_escalation in trigger_names
    end
  end
end
