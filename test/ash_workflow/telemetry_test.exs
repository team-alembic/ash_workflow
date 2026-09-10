defmodule AshWorkflow.TelemetryTest do
  @moduledoc """
  `AshWorkflow.Changes.RecordEvent` emits the transition span, and that change
  runs on every action AshWorkflow generates. So what these tests check is that
  one span arrives per state change whatever caused it — a create, a manual
  transition, an automatic step, a timeout, an error path — and that
  `triggered_by` says which.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.ApprovalWorkflow
  alias AshWorkflowTest.ConditionalWorkflow
  alias AshWorkflowTest.ErrorPathWorkflow
  alias AshWorkflowTest.FullPipeline
  alias AshWorkflowTest.TimeoutWorkflow

  @start [:ash_workflow, :transition, :start]
  @stop [:ash_workflow, :transition, :stop]
  @route [:ash_workflow, :route_evaluation]

  setup do
    ref = make_ref()
    handler_id = "test-#{inspect(ref)}"
    pid = self()

    :telemetry.attach_many(
      handler_id,
      [@start, @stop, @route],
      fn event, measurements, metadata, _config ->
        send(pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref}
  end

  # A telemetry handler is attached process-wide, so with async: true this
  # test's handler also receives events caused by tests running concurrently.
  # Matching the record's own id is what keeps them apart. Matching only the
  # resource lets another test's ApprovalWorkflow create satisfy the assertion,
  # which is exactly how this first went wrong.
  defp await(ref, event, resource, id, timeout \\ 500) do
    receive do
      {^ref, ^event, measurements, %{resource: ^resource, workflow_id: ^id} = metadata} ->
        {measurements, metadata}

      {^ref, ^event, _measurements, _elsewhere} ->
        await(ref, event, resource, id, timeout)
    after
      timeout -> flunk("no #{inspect(event)} for #{inspect(resource)} #{inspect(id)}")
    end
  end

  # A create emits a span of its own, so a test that acts on an existing record
  # has to clear it first: both spans carry the same workflow_id, and the
  # create's arrives first.
  defp drain(ref) do
    receive do
      {^ref, _event, _measurements, _metadata} -> drain(ref)
    after
      0 -> :ok
    end
  end

  defp await_route(ref, resource, from_state, timeout \\ 500) do
    receive do
      {^ref, @route, measurements, %{resource: ^resource, from_state: ^from_state} = metadata} ->
        {measurements, metadata}

      {^ref, _event, _measurements, _elsewhere} ->
        await_route(ref, resource, from_state, timeout)
    after
      timeout -> flunk("no route evaluation for #{inspect(resource)}")
    end
  end

  describe "a manual transition" do
    test "emits a start and a stop", %{ref: ref} do
      {:ok, record} = ApprovalWorkflow.create(%{title: "test"})
      drain(ref)

      Ash.update!(record, action: :approve)

      {measurements, metadata} = await(ref, @start, ApprovalWorkflow, record.id)

      assert %{system_time: _} = measurements
      assert metadata.from_state == :review
      assert metadata.to_state == :approved
      assert metadata.action == :approve
      assert metadata.transition_name == :approve
      assert metadata.triggered_by == :manual

      {measurements, metadata} = await(ref, @stop, ApprovalWorkflow, record.id)

      assert %{system_time: _, duration: duration} = measurements
      assert duration >= 0
      assert metadata.to_state == :approved
      assert metadata.triggered_by == :manual
    end
  end

  describe "triggered_by names what caused the transition" do
    test "creating a record is :initial, with no from_state", %{ref: ref} do
      {:ok, record} = ApprovalWorkflow.create(%{title: "test"})

      # A create has no `changeset.data`, so `:start` carries no workflow_id.
      # `:stop` reads it from the record the action returned, which is the only
      # point at which the id exists.
      {_measurements, metadata} = await(ref, @stop, ApprovalWorkflow, record.id)

      assert metadata.triggered_by == :initial
      assert metadata.from_state == nil
      assert metadata.to_state == :review
    end

    test "an automatic step is :automatic", %{ref: ref} do
      {:ok, record} = FullPipeline.create(%{title: "test"})
      drain(ref)

      Ash.update!(record, action: :run_intake)

      {_measurements, metadata} = await(ref, @start, FullPipeline, record.id)

      assert metadata.triggered_by == :automatic
      assert metadata.action == :run_intake
    end

    test "a timeout is :timeout, and carries the timeout's own name", %{ref: ref} do
      record =
        TimeoutWorkflow
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      drain(ref)

      Ash.update!(record, action: :__timeout_waiting_escalation)

      {_measurements, metadata} = await(ref, @start, TimeoutWorkflow, record.id)

      assert metadata.triggered_by == :timeout
      # The action is the generated hidden one; the transition name is what a
      # person wrote in the DSL, which is what a dashboard should group by.
      assert metadata.action == :__timeout_waiting_escalation
      assert metadata.transition_name == :escalation
    end

    test "an error path is :error_path", %{ref: ref} do
      {:ok, record} = ErrorPathWorkflow.create(%{title: "test", should_fail: true})
      drain(ref)

      Ash.update!(record, action: :__on_error_process)

      {_measurements, metadata} = await(ref, @start, ErrorPathWorkflow, record.id)

      assert metadata.triggered_by == :error_path
      assert metadata.transition_name == :do_processing
    end
  end

  describe "a conditional transition" do
    test "reports the route it matched", %{ref: ref} do
      {:ok, record} = ConditionalWorkflow.create(%{title: "test", path_type: :full})
      drain(ref)

      Ash.update!(record, action: :complete)

      {_measurements, metadata} = await_route(ref, ConditionalWorkflow, :compliance)

      assert metadata.transition_name == :complete
      assert metadata.routes_evaluated == 2
      assert metadata.matched_route in [:training, :fast_track]
    end

    test "start has no to_state, and stop has the one the record landed in", %{ref: ref} do
      # The target is chosen at runtime, so there is no declared target to
      # report. This is the case that makes to_state nullable on :start.
      {:ok, record} = ConditionalWorkflow.create(%{title: "test", path_type: :abbreviated})
      drain(ref)

      Ash.update!(record, action: :complete)

      {_measurements, start_metadata} = await(ref, @start, ConditionalWorkflow, record.id)
      {_measurements, stop_metadata} = await(ref, @stop, ConditionalWorkflow, record.id)

      assert start_metadata.to_state == nil
      assert stop_metadata.to_state == :fast_track
    end
  end

  describe "with no handler attached" do
    test "nothing raises" do
      assert {:ok, record} = ApprovalWorkflow.create(%{title: "test"})
      assert {:ok, _approved} = Ash.update(record, action: :approve)
    end
  end
end
