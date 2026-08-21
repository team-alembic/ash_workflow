defmodule AshWorkflow.CheckIntervalTest do
  @moduledoc """
  Every automatic step and every timeout gets its own Oban scheduler, and each
  polls on its own cron, so the interval is the knob that controls how much
  querying a workflow costs at rest.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.CheckIntervalWorkflow
  alias AshWorkflowTest.TimeoutWorkflow

  defp cron_for(resource, trigger_name) do
    resource
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == trigger_name))
    |> Map.fetch!(:scheduler_cron)
  end

  describe "workflow-level check_interval" do
    test "defaults to every minute when not declared" do
      assert cron_for(TimeoutWorkflow, :__timeout_trigger_reminder) == "* * * * *"
    end

    test "applies to automatic step triggers" do
      assert cron_for(CheckIntervalWorkflow, :processing) == "0 * * * *"
    end

    test "applies to timeouts that do not declare their own" do
      assert cron_for(CheckIntervalWorkflow, :__timeout_trigger_inherits) == "0 * * * *"
    end
  end

  describe "timeout-level check_interval" do
    test "overrides the workflow-level setting" do
      assert cron_for(CheckIntervalWorkflow, :__timeout_trigger_overrides) == "0 9 * * *"
    end

    test "still applies when the workflow declares no default" do
      assert cron_for(AshWorkflowTest.FieldTimeoutWorkflow, :__timeout_trigger_inactivity) ==
               "* * * * *"
    end
  end
end
