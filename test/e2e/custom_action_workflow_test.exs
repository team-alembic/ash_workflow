defmodule AshWorkflowTest.E2E.CustomActionWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.CustomActionWorkflow

  describe "user-defined transition actions" do
    test "approve transitions state even though action is user-defined" do
      {:ok, workflow} = CustomActionWorkflow.create(%{title: "test"})
      assert workflow.state == :review

      {:ok, workflow} = CustomActionWorkflow.approve(workflow)
      assert workflow.state == :approved
    end

    test "approve sets the user-defined approved_at timestamp" do
      {:ok, workflow} = CustomActionWorkflow.create(%{title: "test"})
      {:ok, workflow} = CustomActionWorkflow.approve(workflow)

      assert workflow.approved_at != nil
    end

    test "approve updates state_entered_at" do
      {:ok, workflow} = CustomActionWorkflow.create(%{title: "test"})
      original_entered_at = workflow.state_entered_at

      {:ok, workflow} = CustomActionWorkflow.approve(workflow)
      assert workflow.state_entered_at >= original_entered_at
    end

    test "reject transitions state and accepts the reason field" do
      {:ok, workflow} = CustomActionWorkflow.create(%{title: "test"})

      {:ok, workflow} =
        CustomActionWorkflow.reject(workflow, %{reason: "Not qualified"})

      assert workflow.state == :rejected
      assert workflow.reason == "Not qualified"
    end
  end
end
