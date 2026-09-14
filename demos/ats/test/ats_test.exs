defmodule AshWorkflowDemo.ATSTest do
  @moduledoc """
  The point of this demo is a workflow you watch happen: nobody calls the
  scoring steps, a per-candidate deadline lets each one run, and a single
  `:offer` sweeps every rival off the board.

  Tests here drive the workflow through its scheduler triggers wherever the
  stage does, rather than calling the generated actions directly — a demo
  whose actions work but whose triggers do not is a demo that fails in the
  room.

  Janine's and Steve's scores are drawn at random, so a couple of tests retry
  a fresh candidate until they land on the branch under test rather than
  asserting on a single draw.
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

  defp drive_lead_decision(candidate) do
    candidate
    |> ready_for_lead_decision()
    |> then(fn c ->
      run_workflow_triggers(Candidate)
      reload(c)
    end)
  end

  # Retries a fresh candidate through `attempt` until one lands in `state`,
  # since Janine and Steve draw a random score each time.
  defp until_state(state, attempt, tries \\ 100) do
    Enum.find_value(1..tries, fn _ ->
      candidate = attempt.()
      if candidate.state == state, do: candidate
    end) || flunk("never reached #{state} in #{tries} tries")
  end

  defp reach_background_check(name \\ "Alice") do
    until_state(:background_check, fn -> name |> start_candidate() |> drive_hr_decision() end)
  end

  describe "start/3" do
    test "creates a candidate on :hr_screen" do
      candidate = start_candidate()

      assert candidate.state == :hr_screen
      assert candidate.name == "Alice"
      assert candidate.score == nil
    end

    test "stamps an hr_respond_after deadline Janine has to wait for" do
      assert %DateTime{} = start_candidate().hr_respond_after
    end
  end

  describe "record_hr_screen" do
    test "sets a score, a reason in Janine's voice, and a dbs_reference" do
      candidate = start_candidate() |> drive_hr_decision()

      assert candidate.score in 1..10
      assert is_binary(candidate.score_reason)
      assert is_binary(candidate.dbs_reference)
    end

    test "a passing score routes to :background_check" do
      candidate = reach_background_check()

      assert candidate.score >= 4
    end

    test "a failing score routes to :rejected" do
      candidate =
        until_state(:rejected, fn -> start_candidate() |> drive_hr_decision() end)

      assert candidate.score < 4
    end

    test "nothing but the timeout can move a candidate out of :hr_screen" do
      candidate = start_candidate()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(candidate, action: :offer, authorize?: false)

      assert reload(candidate).state == :hr_screen
    end
  end

  describe "the background check" do
    test "a :clear result from the bureau reaches :lead_interview" do
      candidate = reach_background_check()

      assert {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)

      assert cleared.state == :lead_interview
      assert cleared.dbs_offence == nil
    end

    test "a :flagged result reaches :lead_interview and records a non-nil offence" do
      candidate = reach_background_check()

      assert {:ok, flagged} = DbsBureau.return_result(candidate.dbs_reference, :flagged)

      assert flagged.state == :lead_interview
      assert is_binary(flagged.dbs_offence)
    end

    test "a duplicate reference is reported rather than reapplied" do
      candidate = reach_background_check()
      {:ok, _} = DbsBureau.return_result(candidate.dbs_reference, :clear)

      assert DbsBureau.return_result(candidate.dbs_reference, :clear) == :already_returned
    end

    test "an unknown reference is reported rather than raised" do
      assert DbsBureau.return_result("DBS-NOTREAL", :clear) == :unknown_reference
    end
  end

  describe "record_lead_interview" do
    defp reach_lead_interview(name \\ "Alice") do
      candidate = reach_background_check(name)
      {:ok, cleared} = DbsBureau.return_result(candidate.dbs_reference, :clear)
      cleared
    end

    test "sets lead_score and lead_note" do
      candidate = reach_lead_interview() |> drive_lead_decision()

      assert candidate.lead_score in 1..10
      assert is_binary(candidate.lead_note)
    end

    test "a passing lead_score routes to :final_approval" do
      candidate =
        until_state(:final_approval, fn -> reach_lead_interview() |> drive_lead_decision() end)

      assert candidate.lead_score >= 4
    end

    test "a failing lead_score routes to :rejected" do
      candidate =
        until_state(:rejected, fn -> reach_lead_interview() |> drive_lead_decision() end)

      assert candidate.lead_score < 4
    end
  end

  describe "offer" do
    defp reach_final_approval(name \\ "Alice") do
      until_state(:final_approval, fn ->
        reach_lead_interview(name) |> drive_lead_decision()
      end)
    end

    test "reaches :hired" do
      winner = reach_final_approval()

      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      assert hired.state == :hired
    end

    test "sweeps every other in-flight candidate to :rejected" do
      winner = reach_final_approval("Winner")
      on_hr_screen = start_candidate("StillOnHrScreen")
      on_background_check = reach_background_check("StillOnBackgroundCheck")
      on_lead_interview = reach_lead_interview("StillOnLeadInterview")

      {:ok, _} = ATS.offer(winner, %{}, authorize?: false)

      assert reload(on_hr_screen).state == :rejected
      assert reload(on_background_check).state == :rejected
      assert reload(on_lead_interview).state == :rejected
    end

    test "leaves already-terminal candidates untouched" do
      winner = reach_final_approval("Winner")

      already_rejected =
        until_state(:rejected, fn -> start_candidate() |> drive_hr_decision() end)

      {:ok, _} = ATS.offer(winner, %{}, authorize?: false)

      assert reload(already_rejected).state == :rejected
    end

    test "offering twice is refused — the slot is gone" do
      winner = reach_final_approval()
      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = ATS.offer(hired, %{}, authorize?: false)
    end

    test "a dbs_offence recorded before :lead_interview survives all the way to :hired" do
      winner =
        until_state(:final_approval, fn ->
          candidate = reach_background_check()
          {:ok, flagged} = DbsBureau.return_result(candidate.dbs_reference, :flagged)
          drive_lead_decision(flagged)
        end)

      assert is_binary(winner.dbs_offence)

      {:ok, hired} = ATS.offer(winner, %{}, authorize?: false)

      assert hired.state == :hired
      assert hired.dbs_offence == winner.dbs_offence
    end
  end

  describe "veto" do
    test "moves a candidate on :final_approval to :rejected without a sweep" do
      candidate = reach_final_approval("VetoMe")
      bystander = start_candidate("Bystander")

      {:ok, vetoed} = ATS.veto(candidate, %{}, authorize?: false)

      assert vetoed.state == :rejected
      assert reload(bystander).state == :hr_screen
    end
  end

  describe "code interface" do
    test "list_candidates returns all" do
      start_candidate("A")
      start_candidate("B")

      %Ash.Page.Keyset{results: candidates} = ATS.list_candidates!(authorize?: false)

      assert length(candidates) == 2
    end

    test "get_candidate/1 by id" do
      candidate = start_candidate()

      assert {:ok, fetched} = ATS.get_candidate(candidate.id)
      assert fetched.id == candidate.id
    end
  end
end
