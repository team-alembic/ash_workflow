defmodule AshWorkflowTest.E2E.SharedConditionalWorkflowTest do
  use ExUnit.Case

  alias AshWorkflowTest.SharedConditionalWorkflow

  describe "shared :advance with conditional routing at one step" do
    test "full path: screening → review → compliance → training → done" do
      {:ok, wf} = SharedConditionalWorkflow.start(%{title: "test", path_type: :full})
      assert wf.state == :screening

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :review

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :compliance

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :training

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :done
    end

    test "abbreviated path: screening → review → compliance → fast_track → done" do
      {:ok, wf} = SharedConditionalWorkflow.start(%{title: "test", path_type: :abbreviated})
      assert wf.state == :screening

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :review

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :compliance

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :fast_track

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :done
    end

    test "conditional route from compliance does not match when in training" do
      # This is the exact regression: an agency/full path_type candidate
      # advances through training, and the compliance conditional route
      # (path_type == :full → :training) must NOT match from the training step.
      {:ok, wf} = SharedConditionalWorkflow.start(%{title: "test", path_type: :full})

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :training

      # This must go to :done, not back to :training
      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :done
    end

    test "conditional route from compliance does not match when in fast_track" do
      {:ok, wf} = SharedConditionalWorkflow.start(%{title: "test", path_type: :abbreviated})

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :fast_track

      {:ok, wf} = SharedConditionalWorkflow.advance(wf)
      assert wf.state == :done
    end
  end
end
