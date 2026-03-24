defmodule AshWorkflow.Transformers.AddPoliciesTest do
  use ExUnit.Case

  alias Ash.Policy.Info, as: PolicyInfo

  test "generates policies for manual steps with policy declarations" do
    policies = PolicyInfo.policies(AshWorkflowTest.Domain, AshWorkflowTest.PolicyWorkflow)

    assert policies != []
  end

  test "no policies generated for steps without policy" do
    policies = PolicyInfo.policies(AshWorkflowTest.Domain, AshWorkflowTest.ApprovalWorkflow)

    assert policies == []
  end

  test "full pipeline generates policies for each step with policy" do
    policies = PolicyInfo.policies(AshWorkflowTest.Domain, AshWorkflowTest.FullPipeline)

    assert Enum.count(policies) == 5
  end
end
