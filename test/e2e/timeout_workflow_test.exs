defmodule AshWorkflowTest.E2E.TimeoutWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.TimeoutWorkflow

  describe "DSL compilation" do
    test "resource compiles with timeouts" do
      assert TimeoutWorkflow.__info__(:module) == TimeoutWorkflow
    end
  end

  describe "generated oban triggers for timeouts" do
    test "has oban triggers defined" do
      triggers = AshOban.Info.oban_triggers(TimeoutWorkflow)
      assert length(triggers) > 0
    end

    test "has a trigger for the reminder timeout" do
      triggers = AshOban.Info.oban_triggers(TimeoutWorkflow)

      reminder =
        Enum.find(
          triggers,
          &(&1.name == :waiting_reminder || String.contains?(to_string(&1.name), "reminder"))
        )

      assert reminder
    end

    test "has a trigger for the escalation timeout" do
      triggers = AshOban.Info.oban_triggers(TimeoutWorkflow)

      escalation =
        Enum.find(
          triggers,
          &(&1.name == :waiting_escalation || String.contains?(to_string(&1.name), "escalation"))
        )

      assert escalation
    end
  end

  describe "timeout behavior" do
    test "manual resolve transitions to resolved" do
      {:ok, workflow} = TimeoutWorkflow.start(%{title: "test"})
      {:ok, workflow} = TimeoutWorkflow.resolve(workflow)
      assert workflow.state == :resolved
    end
  end
end
