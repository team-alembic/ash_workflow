defmodule AshWorkflow.TelemetryTest do
  use ExUnit.Case, async: true

  setup do
    ref = make_ref()
    pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(pid, {ref, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "test-#{inspect(ref)}",
      [
        [:ash_workflow, :transition, :start],
        [:ash_workflow, :transition, :stop],
        [:ash_workflow, :route_evaluation]
      ],
      handler,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-#{inspect(ref)}") end)

    %{ref: ref}
  end

  defp receive_event(ref, event_name, resource) do
    receive_event(ref, event_name, resource, 100)
  end

  defp receive_event(ref, event_name, resource, timeout) do
    receive do
      {^ref, ^event_name, measurements, %{resource: ^resource} = metadata} ->
        {measurements, metadata}

      {^ref, ^event_name, _measurements, _metadata} ->
        receive_event(ref, event_name, resource, timeout)
    after
      timeout -> flunk("Expected #{inspect(event_name)} for #{inspect(resource)}")
    end
  end

  describe "manual transition telemetry" do
    test "emits start and stop events on manual transition", %{ref: ref} do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      Ash.update!(record, action: :approve)

      {measurements, metadata} =
        receive_event(ref, [:ash_workflow, :transition, :start], AshWorkflowTest.ApprovalWorkflow)

      assert %{system_time: _} = measurements
      assert metadata.from_state == :review
      assert metadata.transition_name == :approve
      assert metadata.trigger == :manual
      assert metadata.workflow_id == record.id

      {measurements, metadata} =
        receive_event(ref, [:ash_workflow, :transition, :stop], AshWorkflowTest.ApprovalWorkflow)

      assert %{system_time: _, duration: duration} = measurements
      assert duration >= 0
      assert metadata.to_state == :approved
      assert metadata.trigger == :manual
    end
  end

  describe "conditional transition telemetry" do
    test "emits route evaluation event", %{ref: ref} do
      {:ok, _record} =
        AshWorkflowTest.ConditionalWorkflow.create(%{title: "test", path_type: :full})

      Ash.update!(Ash.get!(AshWorkflowTest.ConditionalWorkflow, _record.id), action: :complete)

      {_measurements, metadata} =
        receive_event(
          ref,
          [:ash_workflow, :route_evaluation],
          AshWorkflowTest.ConditionalWorkflow
        )

      assert metadata.transition_name == :complete
      assert metadata.from_state == :compliance
      assert metadata.matched_route == :training
      assert metadata.routes_evaluated == 2
    end

    test "emits route evaluation for abbreviated path", %{ref: ref} do
      {:ok, record} =
        AshWorkflowTest.ConditionalWorkflow.create(%{title: "test", path_type: :abbreviated})

      Ash.update!(record, action: :complete)

      {_measurements, metadata} =
        receive_event(
          ref,
          [:ash_workflow, :route_evaluation],
          AshWorkflowTest.ConditionalWorkflow
        )

      assert metadata.matched_route == :fast_track
    end
  end

  describe "transition metadata" do
    test "includes workflow_id from primary key", %{ref: ref} do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      Ash.update!(record, action: :reject)

      {_measurements, metadata} =
        receive_event(ref, [:ash_workflow, :transition, :start], AshWorkflowTest.ApprovalWorkflow)

      assert metadata.workflow_id == record.id
    end

    test "includes action name", %{ref: ref} do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      Ash.update!(record, action: :approve)

      {_measurements, metadata} =
        receive_event(ref, [:ash_workflow, :transition, :start], AshWorkflowTest.ApprovalWorkflow)

      assert metadata.action == :approve
    end
  end
end
