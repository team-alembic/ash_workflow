defmodule AshWorkflowTest.Postgres.OnSuccessObanTest do
  @moduledoc """
  Exercises conditional `on_success` against a real database and a real Oban.

  Generated-DSL tests (`test/ash_workflow/on_success_test.exs`) assert
  what the transformers *generate* and exercise routing by calling the
  action directly. This proves the whole thing actually runs end to end
  through the same Oban scheduler/trigger path a production deployment
  would use — different records genuinely take different paths through the
  same automatic step, driven by real, persisted attribute values.
  """
  use AshWorkflowTest.DataCase

  alias AshWorkflowTest.Postgres.ScreeningWorkflow

  defp submit(attrs \\ %{}) do
    ScreeningWorkflow.submit!(Map.merge(%{candidate_name: "Some Candidate"}, attrs))
  end

  defp run_trigger! do
    AshOban.schedule_and_run_triggers(ScreeningWorkflow)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)
  end

  describe "conditional routing driven by a real Oban trigger" do
    test "a strong candidate is routed to interview" do
      workflow = submit(%{candidate_name: "Strong Candidate"})
      assert workflow.state == :screening

      run_trigger!()

      reloaded = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :interview
      assert reloaded.screen_score == 8
    end

    test "a weak candidate is routed to rejected_by_hr — a different record, different path" do
      workflow = submit(%{candidate_name: "Weak Candidate"})
      assert workflow.state == :screening

      run_trigger!()

      reloaded = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :rejected_by_hr
      assert reloaded.screen_score == 2
    end

    test "state_entered_at is re-stamped on a conditionally routed transition" do
      workflow = submit(%{candidate_name: "Strong Candidate"})

      run_trigger!()

      reloaded = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert DateTime.compare(reloaded.state_entered_at, workflow.state_entered_at) == :gt
    end

    test "on_error still routes independently when the action fails" do
      workflow = submit(%{candidate_name: "Strong Candidate", should_fail: true})

      run_trigger!()

      reloaded = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert reloaded.state == :screening_failed
    end

    test "a routed record is not re-enqueued" do
      submit(%{candidate_name: "Strong Candidate"})
      run_trigger!()

      AshOban.schedule_and_run_triggers(ScreeningWorkflow)

      refute_enqueued(
        worker:
          AshOban.Info.oban_triggers(ScreeningWorkflow)
          |> Enum.find(&(&1.action == :run_screening))
          |> Map.fetch!(:worker)
      )
    end

    test "a conditionally-routed terminal target receives no further triggers of any kind" do
      workflow = submit(%{candidate_name: "Strong Candidate"})
      run_trigger!()

      routed = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert routed.state == :interview

      # :interview is terminal — the workflow declares exactly one Oban
      # trigger (:run_screening), so re-scheduling and draining every worker
      # must leave the record untouched, whichever conditional target it
      # landed on.
      AshOban.schedule_and_run_triggers(ScreeningWorkflow)
      assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :workflow, with_recursion: true)

      still_routed = Ash.get!(ScreeningWorkflow, workflow.id, authorize?: false)
      assert still_routed.state == :interview
      assert DateTime.compare(still_routed.state_entered_at, routed.state_entered_at) == :eq
    end
  end
end
