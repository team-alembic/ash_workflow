defmodule AshWorkflow.Transformers.AddPoliciesTest do
  use ExUnit.Case

  alias Ash.Policy.Check.Action, as: ActionCheck
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

  describe "on_error actions on an authorized resource" do
    alias AshWorkflowTest.AuthorizedErrorPathWorkflow, as: Workflow

    test "the generated on_error action is permitted without an actor" do
      {:ok, record} = Workflow.create(%{title: "test"}, authorize?: false)

      # AshOban runs this action with no actor when an automatic step fails. If
      # it is not covered by the generated policies, a failing step is silently
      # unable to reach its error state.
      assert {:ok, failed} = Ash.update(record, %{}, action: :__on_error_processing)
      assert failed.state == :failed
    end

    test "the on_error action is covered by the AshOban bypass" do
      bypass_actions =
        AshWorkflowTest.Domain
        |> PolicyInfo.policies(Workflow)
        |> Enum.filter(& &1.bypass?)
        |> Enum.flat_map(& &1.condition)
        |> Enum.flat_map(fn
          {ActionCheck, opts} -> List.wrap(opts[:action])
          _ -> []
        end)

      assert :__on_error_processing in bypass_actions
    end
  end
end
