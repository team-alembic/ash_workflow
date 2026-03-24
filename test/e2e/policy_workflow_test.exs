defmodule AshWorkflowTest.E2E.PolicyWorkflowTest do
  use ExUnit.Case

  alias Ash.Policy.Info, as: PolicyInfo
  alias AshWorkflowTest.PolicyWorkflow

  describe "DSL compilation" do
    test "resource compiles with step-level policies" do
      assert PolicyWorkflow.__info__(:module) == PolicyWorkflow
    end
  end

  describe "generated policies" do
    test "policies are defined on the resource" do
      policies = PolicyInfo.policies(AshWorkflowTest.Domain, PolicyWorkflow)
      assert policies != []
    end

    test "transition actions are covered by policies" do
      policies = PolicyInfo.policies(AshWorkflowTest.Domain, PolicyWorkflow)

      transition_actions = [:approve, :reject]

      for action_name <- transition_actions do
        matching =
          Enum.find(policies, fn policy ->
            case policy.condition do
              [{Ash.Policy.Check.Action, opts}] when is_list(opts) ->
                action_name in List.wrap(opts[:action])

              _ ->
                false
            end
          end)

        assert matching, "Expected a policy covering action #{action_name}"
      end
    end
  end

  describe "policy enforcement" do
    test "manager can approve" do
      {:ok, workflow} = PolicyWorkflow.start(%{title: "test"})
      actor = %{role: :manager}
      assert {:ok, _} = PolicyWorkflow.approve(workflow, actor: actor)
    end

    test "non-manager cannot approve" do
      {:ok, workflow} = PolicyWorkflow.start(%{title: "test"})
      actor = %{role: :viewer}
      assert {:error, %Ash.Error.Forbidden{}} = PolicyWorkflow.approve(workflow, actor: actor)
    end

    test "manager can reject" do
      {:ok, workflow} = PolicyWorkflow.start(%{title: "test"})
      actor = %{role: :manager}
      assert {:ok, _} = PolicyWorkflow.reject(workflow, actor: actor)
    end

    test "non-manager cannot reject" do
      {:ok, workflow} = PolicyWorkflow.start(%{title: "test"})
      actor = %{role: :viewer}
      assert {:error, %Ash.Error.Forbidden{}} = PolicyWorkflow.reject(workflow, actor: actor)
    end
  end
end
