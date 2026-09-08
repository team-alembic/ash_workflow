defmodule AshWorkflowTest.Postgres.OnSuccessWithTimeoutObanTest do
  @moduledoc """
  Exercises a step that declares both conditional `on_success` and a
  `timeout`, against a real database and a real Oban, proving the two
  features don't interfere with each other:

  - a record whose step action has already run is routed by `on_success`
    exactly as it would be without the timeout declared
  - a record that hasn't been routed yet (the action trigger never ran) is
    still moved along by the timeout once its deadline passes

  `{resource, trigger_name}` lets each trigger be scheduled and drained in
  isolation — the step's own action trigger is named after the step
  (`:screening`), and its timeout trigger is named
  `:__timeout_trigger_screening_sla` — so the two paths can be exercised
  independently instead of racing in a single shared-queue drain.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.ScreeningWithTimeoutWorkflow, as: Workflow

  defp submit(attrs \\ %{}) do
    Workflow.submit!(Map.merge(%{candidate_name: "Some Candidate"}, attrs))
  end

  defp run_trigger!(trigger_name) do
    AshOban.schedule_and_run_triggers({Workflow, trigger_name})
  end

  test "on_success routing still works on a step that also declares a timeout" do
    workflow = submit(%{candidate_name: "Strong Candidate"})
    assert workflow.state == :screening

    run_trigger!(:screening)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)
    assert reloaded.state == :interview
  end

  test "the timeout still fires for a record that has not yet been routed by on_success" do
    workflow = submit(%{candidate_name: "Weak Candidate"})
    assert workflow.state == :screening
    assert workflow.screen_score == nil

    aged = age_by(workflow, 2, :hour)

    # Deliberately never run the :screening trigger — the record is aged out
    # before its own action ever executes, the same as if Oban had been down
    # or the worker had failed silently.
    run_trigger!(:__timeout_trigger_screening_sla)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, aged.id, authorize?: false)
    assert reloaded.state == :escalated
    assert reloaded.screen_score == nil, "the step's own action never ran"
  end

  test "the timeout does not fire before its deadline, on a step with conditional on_success" do
    workflow = submit(%{candidate_name: "Weak Candidate"})

    run_trigger!(:__timeout_trigger_screening_sla)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    reloaded = Ash.get!(Workflow, workflow.id, authorize?: false)
    assert reloaded.state == :screening
  end

  test "the timeout does not fire for a record on_success already routed away" do
    workflow = submit(%{candidate_name: "Strong Candidate"})

    run_trigger!(:screening)
    Oban.drain_queue(queue: :workflow, with_recursion: true)
    routed = Ash.get!(Workflow, workflow.id, authorize?: false)
    assert routed.state == :interview

    age_by(routed, 2, :hour)
    run_trigger!(:__timeout_trigger_screening_sla)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

    assert Ash.get!(Workflow, workflow.id, authorize?: false).state == :interview
  end
end
