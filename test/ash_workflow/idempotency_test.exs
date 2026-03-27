defmodule AshWorkflow.IdempotencyTest do
  use ExUnit.Case, async: true

  describe "automatic step idempotency" do
    test "re-running an automatic step action after success is rejected by state machine" do
      {:ok, record} =
        AshWorkflowTest.ErrorPathWorkflow.create(%{title: "test", should_fail: false})

      assert record.state == :process

      {:ok, result} = Ash.update(record, action: :do_processing)
      assert result.state == :done

      # Attempting the same action again (e.g., Oban retry) should fail
      # because the state machine no longer allows transitioning from :done
      assert {:error, error} = Ash.update(result, action: :do_processing)
      assert Exception.message(error) =~ "NoMatchingTransition"
    end
  end

  describe "manual transition idempotency" do
    test "re-running a manual transition after success is rejected by state machine" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      assert record.state == :review

      {:ok, result} = Ash.update(record, action: :approve)
      assert result.state == :approved

      assert {:error, error} = Ash.update(result, action: :approve)
      assert Exception.message(error) =~ "NoMatchingTransition"
    end

    test "cannot run a transition from the wrong state" do
      {:ok, record} = AshWorkflowTest.ApprovalWorkflow.create(%{title: "test"})

      {:ok, result} = Ash.update(record, action: :reject)
      assert result.state == :rejected

      # Can't approve from rejected state
      assert {:error, error} = Ash.update(result, action: :approve)
      assert Exception.message(error) =~ "NoMatchingTransition"
    end
  end
end
