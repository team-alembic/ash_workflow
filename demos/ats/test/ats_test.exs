defmodule AshWorkflowDemo.ATSTest do
  @moduledoc """
  The point of this demo is a workflow you watch happen: nobody calls the
  scoring step, a per-candidate deadline lets it run, and a single `:hire`
  sweeps every rival off the board.

  Tests here drive the workflow through its Oban triggers wherever the stage
  does, rather than calling the generated actions directly — a demo whose
  actions work but whose triggers do not is a demo that fails in the room.
  """
  use AshWorkflowDemo.DataCase, async: false

  alias AshWorkflowDemo.ATS
  alias AshWorkflowDemo.ATS.Candidate

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp start_candidate(name \\ "Alice", pitch \\ "I ship") do
    {:ok, candidate} = ATS.start(name, pitch, "https://example.com/avatar.svg")
    candidate
  end

  defp reach_review(name \\ "Alice", pitch \\ "I ship") do
    name
    |> start_candidate(pitch)
    |> ready_to_verify()
    |> then(fn candidate ->
      run_workflow_triggers(Candidate)
      reload(candidate)
    end)
  end

  describe "start/3" do
    test "creates a candidate in the :submitted wait state" do
      candidate = start_candidate()

      assert candidate.state == :submitted
      assert candidate.name == "Alice"
      assert candidate.score == nil
    end

    test "stamps a verify_after deadline the scorer has to wait for" do
      assert %DateTime{} = start_candidate().verify_after
    end

    test "each candidate gets their own deadline" do
      Application.put_env(:ash_workflow_demo, :fast_tests, false)

      deadlines =
        1..12
        |> Enum.map(&start_candidate("Applicant #{&1}").verify_after)
        |> Enum.uniq()

      assert length(deadlines) > 1
    end
  end

  describe "the :submitted wait state" do
    test "a candidate whose deadline has not passed is left alone" do
      candidate = start_candidate()
      set_datetime(candidate, :verify_after, DateTime.add(DateTime.utc_now(), 1, :hour))

      run_workflow_triggers(Candidate)

      reloaded = reload(candidate)
      assert reloaded.state == :submitted
      assert reloaded.score == nil
    end

    test "a candidate whose deadline has passed is verified and scored" do
      candidate = reach_review()

      assert candidate.state == :review
      assert candidate.score in 1..10
      assert is_binary(candidate.score_reason)
    end

    test "nothing but the timeout can move a candidate out of :submitted" do
      candidate = start_candidate()

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(candidate, action: :hire, authorize?: false)

      assert reload(candidate).state == :submitted
    end

    test "the wait is not a sleep — starting many candidates is immediate" do
      Application.put_env(:ash_workflow_demo, :fast_tests, false)

      {elapsed_us, _} =
        :timer.tc(fn -> Enum.each(1..10, &start_candidate("Rush #{&1}")) end)

      assert elapsed_us < 2_000_000
    end
  end

  describe "the automatic :verifying step" do
    test "runs without anybody calling it" do
      assert reach_review().state == :review
    end

    test "an unscorable pitch routes to :verification_failed" do
      candidate = reach_review("Emoji Only", "🎉🎉🎉")

      assert candidate.state == :verification_failed
      assert candidate.score == nil
    end

    test "a failed verification is terminal" do
      candidate = reach_review("Emoji Only", "🎉🎉🎉")

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(candidate, action: :hire, authorize?: false)
    end

    test "one candidate failing does not stop the others being scored" do
      good = start_candidate("Good", "I ship") |> ready_to_verify()
      bad = start_candidate("Bad", "!!!") |> ready_to_verify()

      run_workflow_triggers(Candidate)

      assert reload(good).state == :review
      assert reload(bad).state == :verification_failed
    end
  end

  describe "hire cascade" do
    test "hiring one candidate moves every other reviewable candidate to :position_filled" do
      one = reach_review("One")
      two = reach_review("Two")
      three = reach_review("Three")

      {:ok, hired} = ATS.hire(one, %{}, authorize?: false)

      assert hired.state == :hired
      assert reload(two).state == :position_filled
      assert reload(three).state == :position_filled
    end

    test "leaves terminal candidates untouched" do
      winner = reach_review("Hired")
      rejected = reach_review("Rejected")

      {:ok, rejected} = ATS.reject(rejected, %{}, authorize?: false)
      assert rejected.state == :rejected

      {:ok, _} = ATS.hire(winner, %{}, authorize?: false)

      assert reload(rejected).state == :rejected
    end

    test "a candidate still waiting to be scored is not swept up" do
      winner = reach_review("Winner")
      waiting = start_candidate("Waiting")

      {:ok, _} = ATS.hire(winner, %{}, authorize?: false)

      assert reload(waiting).state == :submitted
    end

    test "hiring twice is refused — the slot is gone" do
      winner = reach_review("Winner")
      {:ok, hired} = ATS.hire(winner, %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = ATS.hire(hired, %{}, authorize?: false)
    end
  end

  describe "reviewer decisions" do
    test "reject moves one candidate without touching the rest" do
      rejected = reach_review("Rejected")
      bystander = reach_review("Bystander")

      {:ok, rejected} = ATS.reject(rejected, %{}, authorize?: false)

      assert rejected.state == :rejected
      assert reload(bystander).state == :review
    end

    test "position_filled is a transition a reviewer can make directly" do
      candidate = reach_review()

      {:ok, candidate} = ATS.position_filled(candidate, %{}, authorize?: false)

      assert candidate.state == :position_filled
    end

    test "every terminal state refuses further transitions" do
      for {name, transition} <- [{"A", :reject}, {"B", :position_filled}] do
        candidate = reach_review(name)
        {:ok, terminal} = Ash.update(candidate, action: transition, authorize?: false)

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.update(terminal, action: :hire, authorize?: false)
      end
    end
  end

  describe "the auto-reject timeout" do
    test "a candidate nobody decides on is auto-rejected once the deadline passes" do
      candidate = reach_review() |> age_by(31, :second)

      run_workflow_triggers(Candidate)

      assert reload(candidate).state == :auto_rejected
    end

    test "a candidate inside the 30 seconds is left in :review" do
      candidate = reach_review() |> age_by(5, :second)

      run_workflow_triggers(Candidate)

      assert reload(candidate).state == :review
    end

    test "the timeout cannot clobber a candidate who was already hired" do
      candidate = reach_review() |> age_by(31, :second)
      {:ok, hired} = ATS.hire(candidate, %{}, authorize?: false)

      run_workflow_triggers(Candidate)

      assert reload(hired).state == :hired
    end

    test "the generated timeout action refuses to fire on a hired candidate" do
      candidate = reach_review()
      {:ok, hired} = ATS.hire(candidate, %{}, authorize?: false)

      assert {:error,
              %Ash.Error.Invalid{errors: [%AshStateMachine.Errors.NoMatchingTransition{}]}} =
               Ash.update(hired, action: :__timeout_review_auto_reject, authorize?: false)
    end

    test "the timeout does not reach a candidate still in :submitted" do
      candidate = start_candidate() |> age_by(31, :second)

      run_workflow_triggers(Candidate)

      refute reload(candidate).state == :auto_rejected
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
