defmodule AshWorkflow.Transformers.AddRelationshipsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo

  test "adds a public has_many :transitions to the transition log resource" do
    relationship = ResourceInfo.relationship(AshWorkflowTest.LoggedWorkflow, :transitions)

    assert relationship.type == :has_many
    assert relationship.destination == AshWorkflowTest.LoggedTransition
    assert relationship.destination_attribute == :workflow_id
    assert relationship.public?
  end

  test "loads the record's transition log rows" do
    {:ok, record} = AshWorkflowTest.LoggedWorkflow.create(%{title: "test"})
    {:ok, record} = Ash.update(record, action: :process_intake)

    loaded = Ash.load!(record, :transitions, authorize?: false)

    assert Enum.sort(Enum.map(loaded.transitions, & &1.id)) ==
             Enum.sort(Enum.map(AshWorkflow.TransitionLog.history(record), & &1.id))

    assert Enum.sort(Enum.map(loaded.transitions, & &1.to_state)) == [:intake, :review]
  end

  test "keeps a user-defined :transitions relationship" do
    relationship = ResourceInfo.relationship(AshWorkflowTest.OwnTransitionsWorkflow, :transitions)

    assert relationship.destination == AshWorkflowTest.OwnTransitionsLog
    refute relationship.public?
  end

  test "adds nothing to a resource without a transition_log" do
    refute ResourceInfo.relationship(AshWorkflowTest.Workflow, :transitions)
  end
end
