defmodule AshWorkflow.Transformers.AddFieldTimeoutTriggersTest do
  use ExUnit.Case

  alias AshWorkflowTest.FieldTimeoutWorkflow
  alias AshWorkflowTest.TimeoutWorkflow

  defp timeout_trigger(resource, trigger_name) do
    resource
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == trigger_name))
  end

  defp matching_records(resource, trigger) do
    resource
    |> Ash.Query.do_filter(trigger.where)
    |> Ash.read!()
    |> Map.get(:results)
  end

  describe "field-based timeout triggers" do
    test "matches records where the custom field is past the deadline" do
      four_days_ago = DateTime.add(DateTime.utc_now(), -4, :day)
      {:ok, old} = FieldTimeoutWorkflow.create(%{title: "old", last_session_date: four_days_ago})

      trigger = timeout_trigger(FieldTimeoutWorkflow, :__timeout_trigger_active_inactivity)
      matches = matching_records(FieldTimeoutWorkflow, trigger)

      assert old.id in Enum.map(matches, & &1.id)
    end

    test "does not match records where the custom field is recent" do
      {:ok, recent} =
        FieldTimeoutWorkflow.create(%{title: "recent", last_session_date: DateTime.utc_now()})

      trigger = timeout_trigger(FieldTimeoutWorkflow, :__timeout_trigger_active_inactivity)
      matches = matching_records(FieldTimeoutWorkflow, trigger)

      refute recent.id in Enum.map(matches, & &1.id)
    end

    test "does not match records where the custom field is nil" do
      {:ok, no_date} = FieldTimeoutWorkflow.create(%{title: "no_date"})

      trigger = timeout_trigger(FieldTimeoutWorkflow, :__timeout_trigger_active_inactivity)
      matches = matching_records(FieldTimeoutWorkflow, trigger)

      refute no_date.id in Enum.map(matches, & &1.id)
    end

    test "default field matches based on state_entered_at" do
      {:ok, workflow} = TimeoutWorkflow.create(%{title: "test"})

      # Just entered the state — state_entered_at is now, so 2-day timeout should not match
      trigger = timeout_trigger(TimeoutWorkflow, :__timeout_trigger_waiting_reminder)
      matches = matching_records(TimeoutWorkflow, trigger)

      refute workflow.id in Enum.map(matches, & &1.id)
    end
  end
end
