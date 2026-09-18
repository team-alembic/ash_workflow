defmodule AshWorkflowDemo.CandidateTransitionTest do
  @moduledoc """
  The transition log itself, independent of any LiveView: every
  `triggered_by` value, `state_at/2` before the first row / between two rows
  / after the last, and undo appending a row rather than editing the one it
  reverses.
  """

  use AshWorkflowDemo.DataCase, async: false

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate
  alias AshWorkflowDemo.ATS.DbsBureau

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp start_candidate(name \\ "Alice", pitch \\ "I ship") do
    {:ok, candidate} = ATS.start(name, pitch, "https://example.com/avatar.svg")
    candidate
  end

  defp drive_hr_decision(candidate) do
    candidate
    |> ready_for_hr_decision()
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  defp drive_bureau_timeout(candidate) do
    candidate
    |> age_by(91, :second)
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  defp drive_lead_decision(candidate) do
    candidate
    |> ready_for_lead_decision()
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  defp until_state(state, attempt, tries \\ 100) do
    Enum.find_value(1..tries, fn _ ->
      candidate = attempt.()
      if candidate.state == state, do: candidate
    end) || flunk("never reached #{state} in #{tries} tries")
  end

  defp reach_background_check(name \\ "Alice") do
    until_state(:background_check, fn -> name |> start_candidate() |> drive_hr_decision() end)
  end

  defp names(history) do
    Enum.map(history, &{&1.from_state, &1.to_state, &1.transition_name, &1.triggered_by})
  end

  describe "the :initial row" do
    test "is written on create with a nil from_state and triggered_by: :initial" do
      candidate = start_candidate()

      assert [row] = Candidate.history(candidate)
      assert row.from_state == nil
      assert row.to_state == :hr_screen
      assert row.transition_name == :start
      assert row.triggered_by == :initial
    end
  end

  describe "automatic steps" do
    test "a passing score writes triggered_by: :automatic" do
      candidate = reach_background_check()

      assert [_initial, _timeout, automatic] = Candidate.history(candidate)
      assert automatic.from_state == :hr_decision
      assert automatic.to_state == :background_check
      assert automatic.transition_name == :record_hr_screen
      assert automatic.triggered_by == :automatic
    end

    test "the on_error path writes triggered_by: :error_path" do
      candidate =
        "Unreadable" |> start_candidate("12345") |> drive_hr_decision()

      assert candidate.state == :rejected

      assert [_initial, _timeout, error_row] = Candidate.history(candidate)
      assert error_row.from_state == :hr_decision
      assert error_row.to_state == :rejected
      assert error_row.transition_name == :record_hr_screen
      assert error_row.triggered_by == :error_path
    end
  end

  describe "manual transitions" do
    test ":dbs_clear writes triggered_by: :manual" do
      candidate = reach_background_check()

      {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)

      assert names(Candidate.history(cleared)) |> List.last() ==
               {:background_check, :lead_interview, :dbs_clear, :manual}
    end

    test ":dbs_flag writes triggered_by: :manual" do
      candidate = reach_background_check()

      {:ok, flagged} = DbsBureau.return_result(candidate.dbs_reference, :flagged)

      assert names(Candidate.history(flagged)) |> List.last() ==
               {:background_check, :lead_interview, :dbs_flag, :manual}
    end
  end

  describe "timeouts" do
    test "janine_responds writes triggered_by: :timeout" do
      candidate = start_candidate() |> drive_hr_decision()

      assert [_initial, timeout_row | _rest] = Candidate.history(candidate)
      assert timeout_row.from_state == :hr_screen
      assert timeout_row.to_state == :hr_decision
      assert timeout_row.transition_name == :janine_responds
      assert timeout_row.triggered_by == :timeout
    end

    test "bureau_responds writes triggered_by: :timeout, then :bureau_result runs automatically" do
      candidate = reach_background_check() |> drive_bureau_timeout()

      assert candidate.state == :lead_interview

      assert [_initial, _timeout, _automatic, bureau_timeout, bureau_result] =
               Candidate.history(candidate)

      assert bureau_timeout.from_state == :background_check
      assert bureau_timeout.to_state == :bureau_result
      assert bureau_timeout.triggered_by == :timeout

      assert bureau_result.from_state == :bureau_result
      assert bureau_result.to_state == :lead_interview
      assert bureau_result.transition_name == :record_bureau_result
      assert bureau_result.triggered_by == :automatic
    end
  end

  describe "history/1" do
    test "returns rows ordered by occurred_at ascending" do
      candidate = reach_background_check()

      occurred_ats = candidate |> Candidate.history() |> Enum.map(& &1.occurred_at)
      assert occurred_ats == Enum.sort(occurred_ats, DateTime)
    end
  end

  describe "state_at/2" do
    test "returns nil for a time before the earliest logged row" do
      candidate = start_candidate()
      before_creation = DateTime.add(DateTime.utc_now(), -1, :day)

      assert Candidate.state_at(candidate, before_creation) == nil
    end

    test "returns the state active between two logged rows" do
      candidate = start_candidate()
      [initial_row] = Candidate.history(candidate)

      candidate = drive_hr_decision(candidate)
      [_initial, timeout_row | _rest] = Candidate.history(candidate)

      assert Candidate.state_at(candidate, initial_row.occurred_at) == :hr_screen
      assert Candidate.state_at(candidate, timeout_row.occurred_at) == :hr_decision

      between = DateTime.add(timeout_row.occurred_at, 1, :microsecond)
      assert Candidate.state_at(candidate, between) == :hr_decision
    end

    test "returns the current state for a time at or after the last logged row" do
      candidate = reach_background_check()
      after_everything = DateTime.add(DateTime.utc_now(), 1, :day)

      assert Candidate.state_at(candidate, after_everything) == :background_check
    end
  end

  describe "undo" do
    defp reach_final_approval(name \\ "Alice") do
      until_state(:final_approval, fn ->
        candidate = reach_background_check(name)
        {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)
        drive_lead_decision(cleared)
      end)
    end

    test "undoing :offer rewinds to :final_approval and leaves the reversed row struck through" do
      winner = reach_final_approval()
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      assert Candidate.undo_target(hired) == :final_approval

      {:ok, undone} = Ash.update(hired, action: :undo, authorize?: false)
      assert undone.state == :final_approval

      history = Candidate.history(undone)
      assert length(history) == length(Candidate.history(undone, effective: true)) + 1

      offer_row =
        Enum.find(history, &(&1.transition_name == :offer and &1.triggered_by == :manual))

      undo_row = Enum.find(history, &(&1.triggered_by == :undo))

      assert undo_row.undoes_id == offer_row.id
      assert undo_row.from_state == :hired
      assert undo_row.to_state == :final_approval

      refute offer_row.id in Enum.map(Candidate.history(undone, effective: true), & &1.id)
    end

    test "undoing an undo is a redo — it lands back on the state undone away from" do
      winner = reach_final_approval()
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)
      {:ok, undone} = Ash.update(hired, action: :undo, authorize?: false)

      assert Candidate.undo_target(undone) == :hired

      {:ok, redone} = Ash.update(undone, action: :undo, authorize?: false)
      assert redone.state == :hired

      # Both the reversed :offer and the reversed :undo are now superseded —
      # the corrected reading is the raw log minus those two rows.
      assert length(Candidate.history(redone, effective: true)) ==
               length(Candidate.history(redone)) - 2
    end

    test "veto is undoable back to :final_approval" do
      candidate = reach_final_approval()
      {:ok, vetoed} = ATS.veto(candidate, %{}, authorize?: false)

      assert Candidate.undo_target(vetoed) == :final_approval
    end

    test "dbs_clear is undoable back to :background_check" do
      candidate = reach_background_check()
      {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)

      assert Candidate.undo_target(cleared) == :background_check
    end

    test "an automatic step is not undoable" do
      candidate = reach_background_check()

      refute Candidate.undoable?(candidate)
      assert Candidate.undo_target(candidate) == nil

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(candidate, action: :undo, authorize?: false)
    end

    test "the :slot_taken cascade is not undoable from :background_check" do
      winner = reach_final_approval("Winner")
      bystander = reach_background_check("Bystander")

      {:ok, _} = ATS.offer(winner, %{}, authorize?: false)
      swept = reload(bystander)

      assert swept.state == :rejected
      refute Candidate.undoable?(swept)
    end

    # Undo resolves by (from_state, to_state) edge, never by which named
    # transition wrote the row: `AshWorkflow.Info.undoable_edge?/3` only ever
    # sees the pair. :veto and :slot_taken both go :final_approval -> :rejected,
    # so a bystander swept from :final_approval reads as undoable purely
    # because :veto shares that edge — a real property of edge-based undo, not
    # a flag this demo can turn off without giving :veto a different target.
    test "a bystander swept from :final_approval shares :veto's undoable edge" do
      winner = reach_final_approval("Winner")
      bystander = reach_final_approval("Bystander")

      {:ok, _} = ATS.offer(winner, %{}, authorize?: false)
      swept = reload(bystander)

      assert swept.state == :rejected
      assert Candidate.undo_target(swept) == :final_approval
    end

    test "refused once the window has closed" do
      candidate = reach_final_approval()
      {:ok, vetoed} = ATS.veto(candidate, %{}, authorize?: false)

      [_ | _] = Candidate.history(vetoed)
      veto_row = vetoed |> Candidate.history() |> List.last()
      set_datetime(veto_row, :occurred_at, DateTime.add(DateTime.utc_now(), -31, :minute))

      refute Candidate.undoable?(reload(vetoed))
      assert Candidate.undo_target(reload(vetoed)) == nil
    end
  end
end
