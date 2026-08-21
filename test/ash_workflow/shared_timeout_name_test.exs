defmodule AshWorkflow.SharedTimeoutNameTest do
  @moduledoc """
  Timeout names are scoped to the step that declares them, so the same name can
  appear on more than one step — which is the natural way to model "each queue
  has its own SLA".
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.SharedTimeoutNameWorkflow, as: Workflow

  defp trigger_names do
    Workflow |> AshOban.Info.oban_triggers() |> Enum.map(& &1.name) |> MapSet.new()
  end

  test "each step gets its own trigger for a same-named timeout" do
    names = trigger_names()

    assert :__timeout_trigger_urgent_sla_breach in names
    assert :__timeout_trigger_standard_sla_breach in names
    assert :__timeout_trigger_urgent_warn in names
    assert :__timeout_trigger_standard_warn in names
  end

  test "each step gets its own transition action, with its own target" do
    transitions = AshStateMachine.Info.state_machine_transitions(Workflow)

    for step <- [:urgent, :standard] do
      action = :"__timeout_#{step}_sla_breach"

      assert Enum.any?(transitions, &(&1.action == action and step in &1.from)),
             "expected a #{action} transition out of :#{step}"
    end
  end

  test "the two same-named timeouts keep their own durations" do
    durations =
      Workflow
      |> AshOban.Info.oban_triggers()
      |> Map.new(&{&1.name, &1.where})

    # Distinct `where` filters is what proves they were not collapsed into one.
    refute durations[:__timeout_trigger_urgent_sla_breach] ==
             durations[:__timeout_trigger_standard_sla_breach]
  end

  test "worker modules are namespaced by step" do
    assert Workflow.AshWorkflow.Workers.Timeouts.Urgent.SlaBreach
    assert Workflow.AshWorkflow.Workers.Timeouts.Standard.SlaBreach
  end
end
