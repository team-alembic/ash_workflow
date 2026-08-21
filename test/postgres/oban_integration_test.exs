defmodule AshWorkflowTest.Postgres.ObanIntegrationTest do
  @moduledoc """
  Exercises AshWorkflow against a real database and a real Oban.

  The rest of the suite asserts what the transformers *generate*. These tests
  assert that what they generate actually runs: that triggers are enqueued into
  the configured queue, that executing them advances the workflow, and that the
  state columns round-trip through Postgres.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.ApprovalWorkflow

  defp submit(attrs \\ %{}) do
    ApprovalWorkflow.submit!(Map.merge(%{title: "Q1 report"}, attrs))
  end

  describe "workflow initialization" do
    test "creating a record enters the initial step with a persisted timestamp" do
      workflow = submit()

      assert workflow.state == :processing
      assert %DateTime{} = workflow.state_entered_at

      # Round-trip through Postgres, not just the in-memory changeset result.
      reloaded = Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :processing
      assert DateTime.compare(reloaded.state_entered_at, workflow.state_entered_at) == :eq
    end
  end

  describe "automatic step triggers" do
    test "the scheduler enqueues a job for a record sitting in an automatic step" do
      workflow = submit()

      # One non-recursive drain runs the scheduler, which enqueues the per-record
      # worker job without executing it.
      AshOban.schedule_and_run_triggers(ApprovalWorkflow, drain_queues?: false)
      Oban.drain_queue(queue: :workflow, with_recursion: false)

      assert_enqueued(
        worker: worker_for(:process),
        args: %{"primary_key" => %{"id" => workflow.id}}
      )
    end

    test "running the trigger advances the workflow to on_success" do
      workflow = submit()

      AshOban.schedule_and_run_triggers(ApprovalWorkflow)

      assert %{failure: 0, discard: 0} =
               Oban.drain_queue(queue: :workflow, with_recursion: true)

      reloaded = Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :review
      assert reloaded.processed_at, "the user-defined action's own changes should be applied"

      # state_entered_at is re-stamped on transition, which is what timeouts measure from.
      assert DateTime.compare(reloaded.state_entered_at, workflow.state_entered_at) == :gt
    end

    test "a failing automatic step routes to on_error" do
      workflow = submit(%{should_fail: true})

      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      reloaded = Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :failed
    end

    test "an advanced workflow is not re-enqueued" do
      submit()
      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      refute_enqueued(worker: worker_for(:process))
    end
  end

  describe "manual transitions" do
    setup do
      workflow = submit()
      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      %{workflow: Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false)}
    end

    test "a transition action moves the workflow and persists it", %{workflow: workflow} do
      assert workflow.state == :review

      approved = ApprovalWorkflow.approve!(workflow, authorize?: false)
      assert approved.state == :approved

      assert Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false).state == :approved
    end

    test "a manual step is not picked up by an automatic trigger", %{workflow: _workflow} do
      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      refute_enqueued(worker: worker_for(:process))
    end
  end

  describe "timeout triggers" do
    setup do
      workflow = submit()
      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      %{workflow: Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false)}
    end

    test "does not fire before the deadline", %{workflow: workflow} do
      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      assert Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false).state == :review
    end

    test "forces the transition once the deadline has passed", %{workflow: workflow} do
      age_by(workflow, 3, :day)

      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      assert Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false).state == :escalated
    end

    test "does not fire for a workflow that has already left the step", %{workflow: workflow} do
      ApprovalWorkflow.approve!(workflow, authorize?: false)
      age_by(workflow, 3, :day)

      AshOban.schedule_and_run_triggers(ApprovalWorkflow)
      Oban.drain_queue(queue: :workflow, with_recursion: true)

      assert Ash.get!(ApprovalWorkflow, workflow.id, authorize?: false).state == :approved
    end
  end

  defp worker_for(action) do
    AshOban.Info.oban_triggers(ApprovalWorkflow)
    |> Enum.find(&(&1.action == action))
    |> Map.fetch!(:worker)
  end
end
