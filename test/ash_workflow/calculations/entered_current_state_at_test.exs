defmodule AshWorkflow.Calculations.EnteredCurrentStateAtTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo

  describe "registration" do
    test "is only added when a transition_log is configured" do
      assert ResourceInfo.calculation(
               AshWorkflowTest.LoggedWorkflow,
               :entered_current_state_at
             )

      refute ResourceInfo.calculation(AshWorkflowTest.Workflow, :entered_current_state_at)
    end
  end

  describe "value" do
    test "matches state_entered_at when the every hasn't fired yet" do
      {:ok, record} = AshWorkflowTest.LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)

      loaded = Ash.load!(record, [:entered_current_state_at, :state_entered_at])

      # They're set by two separate `DateTime.utc_now/0` calls in the same
      # after_action hook, so they land microseconds apart rather than being
      # bit-for-bit identical.
      assert_in_delta DateTime.diff(
                        loaded.state_entered_at,
                        loaded.entered_current_state_at,
                        :microsecond
                      ),
                      0,
                      50_000
    end

    test "stays fixed while an every fires and keeps state_entered_at moving" do
      {:ok, record} = AshWorkflowTest.LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)

      entered_review_at = Ash.load!(record, :entered_current_state_at).entered_current_state_at

      {:ok, record} = Ash.update(record, action: :send_reminder)
      {:ok, record} = Ash.update(record, action: :send_reminder)

      loaded = Ash.load!(record, [:entered_current_state_at, :state_entered_at])

      assert loaded.entered_current_state_at == entered_review_at
      assert DateTime.compare(loaded.state_entered_at, entered_review_at) == :gt
    end
  end
end
