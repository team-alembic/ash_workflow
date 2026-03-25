defmodule AshWorkflow.Transformers.AddFieldTimeoutTriggersTest do
  use ExUnit.Case

  describe "field-based timeout triggers" do
    test "generates trigger using custom field in where clause" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.FieldTimeoutWorkflow)

      trigger =
        Enum.find(triggers, &(&1.name == :__timeout_trigger_inactivity))

      assert trigger
      assert trigger.action == :__timeout_inactivity

      assert {:_ref, [], :last_session_date} in trigger.where.right.args
    end

    test "default field uses state_entered_at" do
      triggers = AshOban.Info.oban_triggers(AshWorkflowTest.TimeoutWorkflow)

      trigger =
        Enum.find(triggers, &(&1.name == :__timeout_trigger_reminder))

      assert trigger
      assert {:_ref, [], :state_entered_at} in trigger.where.right.args
    end
  end
end
