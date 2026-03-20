defmodule AshWorkflow.Transformers.AddPoliciesTest do
  use ExUnit.Case

  test "generates policies for manual steps with policy declarations" do
    policies = Ash.Policy.Info.policies(AshWorkflowTest.Domain, AshWorkflowTest.PolicyWorkflow)

    assert length(policies) > 0
  end

  test "no policies generated for steps without policy" do
    policies = Ash.Policy.Info.policies(AshWorkflowTest.Domain, AshWorkflowTest.ApprovalWorkflow)

    assert policies == []
  end

  test "full pipeline generates policies for each step with policy" do
    policies = Ash.Policy.Info.policies(AshWorkflowTest.Domain, AshWorkflowTest.FullPipeline)

    # Full pipeline has 3 steps with policies + 1 default allow-all policy
    assert length(policies) == 4
  end
end
