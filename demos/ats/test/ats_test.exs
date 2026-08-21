defmodule AshWorkflowDemo.ATSTest do
  use AshWorkflowDemo.DataCase, async: false

  alias AshWorkflowDemo.ATS

  setup do
    Application.put_env(:ash_workflow_demo, :fast_tests, true)
    on_exit(fn -> Application.put_env(:ash_workflow_demo, :fast_tests, false) end)
    :ok
  end

  defp start_candidate(name \\ "Alice") do
    {:ok, c} =
      ATS.start(name, "I ship", "https://example.com/avatar.svg")

    c
  end

  describe "start/3" do
    test "creates a candidate in :verifying" do
      c = start_candidate()
      assert c.state == :verifying
      assert c.name == "Alice"
      assert c.score == nil
    end
  end

  describe "run_verification transition" do
    test "manual call transitions :verifying -> :review and sets score + reason" do
      c = start_candidate()

      # Call the generated run_verification action directly (bypassing Oban scheduler for determinism).
      {:ok, c} = Ash.update(c, action: :run_verification, authorize?: false)

      assert c.state == :review
      assert is_integer(c.score)
      assert c.score >= 1 and c.score <= 10
      assert is_binary(c.score_reason)
    end
  end

  describe "hire cascade" do
    test "hiring one candidate moves all other non-terminal candidates to :position_filled" do
      c1 = start_candidate("One")
      c2 = start_candidate("Two")
      c3 = start_candidate("Three")

      # Move them all to :review manually
      {:ok, c1} = Ash.update(c1, action: :run_verification, authorize?: false)
      {:ok, c2} = Ash.update(c2, action: :run_verification, authorize?: false)
      {:ok, c3} = Ash.update(c3, action: :run_verification, authorize?: false)

      assert c1.state == :review
      assert c2.state == :review
      assert c3.state == :review

      {:ok, hired} = ATS.hire(c1, %{}, authorize?: false)
      assert hired.state == :hired

      {:ok, c2_after} = ATS.get_candidate(c2.id)
      {:ok, c3_after} = ATS.get_candidate(c3.id)

      assert c2_after.state == :position_filled
      assert c3_after.state == :position_filled
    end

    test "leaves terminal candidates untouched" do
      c1 = start_candidate("Hired")
      c2 = start_candidate("Rejected")

      {:ok, c1} = Ash.update(c1, action: :run_verification, authorize?: false)
      {:ok, c2} = Ash.update(c2, action: :run_verification, authorize?: false)
      {:ok, c2_rejected} = ATS.reject(c2, %{}, authorize?: false)
      assert c2_rejected.state == :rejected

      {:ok, _hired} = ATS.hire(c1, %{}, authorize?: false)

      {:ok, c2_after} = ATS.get_candidate(c2.id)
      assert c2_after.state == :rejected
    end
  end

  describe "auto_reject timeout action" do
    test "the generated __timeout_review_auto_reject action moves :review -> :auto_rejected" do
      c = start_candidate()
      {:ok, c} = Ash.update(c, action: :run_verification, authorize?: false)
      assert c.state == :review

      # Call the generated timeout action directly (skips the time check — that's
      # the Oban trigger's job; we test the action itself here).
      {:ok, c} = Ash.update(c, action: :__timeout_review_auto_reject, authorize?: false)
      assert c.state == :auto_rejected
    end
  end

  describe "code interface" do
    test "list_candidates returns all" do
      _c1 = start_candidate("A")
      _c2 = start_candidate("B")

      %Ash.Page.Keyset{results: candidates} = ATS.list_candidates!(authorize?: false)
      assert length(candidates) == 2
    end

    test "get_candidate/1 by id" do
      c = start_candidate()
      {:ok, fetched} = ATS.get_candidate(c.id)
      assert fetched.id == c.id
    end
  end
end
