defmodule AshWorkflow.Transformers.AddActionsEmitsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Actions.Emit
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Changes.RecordEvent
  alias Spark.Dsl.Extension

  @resource AshWorkflowTest.SignalWorkflow
  @state_signals [:state_changed, :review_started, :review_finished]

  defp declared(action_name) do
    @resource
    |> ResourceInfo.action(action_name)
    |> Map.fetch!(:emits)
  end

  defp plan(action_name) do
    @resource
    |> ResourceInfo.action(action_name)
    |> Map.fetch!(:changes)
    |> Enum.flat_map(fn
      %{change: {RecordEvent, opts}} -> opts[:emits]
      _ -> []
    end)
  end

  test "declares every signal as a dynamic after_action emit of the signals module" do
    for emit <- declared(:approve) do
      assert %Emit{
               signal_module: AshWorkflowTest.Signals,
               dynamic?: true,
               phase: :after_action
             } = emit
    end
  end

  test "state-changing actions declare the workflow and step signals" do
    for action <- [:create, :reject, :screen] do
      assert Enum.map(declared(action), & &1.signal) == @state_signals
    end
  end

  test "a transition, and a transition timeout, also declare their own signals" do
    assert Enum.map(declared(:approve), & &1.signal) == @state_signals ++ [:approved]

    assert Enum.map(declared(:__timeout_review_escalate), & &1.signal) ==
             @state_signals ++ [:escalated]
  end

  test "action timeouts and everys declare only their own signals" do
    assert Enum.map(declared(:send_reminder), & &1.signal) == [:reminded]
    assert Enum.map(declared(:send_nudge), & &1.signal) == [:nudged]
  end

  test "passes the emit plan to RecordEvent" do
    assert [
             %{signal: :state_changed, when: :state_change},
             %{signal: :review_started, when: {:enter, :review}, fields: [name: :name]},
             %{signal: :review_finished, when: {:exit, :review}},
             %{
               signal: :approved,
               when: {:from, :review},
               fields: [name: :name],
               values: [verdict: "approved"]
             }
           ] = plan(:approve)

    assert [%{signal: :escalated, when: :always}] =
             Enum.reject(plan(:__timeout_review_escalate), &(&1.signal in @state_signals))

    assert [%{signal: :nudged, when: {:from, :review}}] = plan(:send_nudge)
  end

  test "the create-time RecordEvent carries the state-change plan" do
    [opts] =
      for %{change: {RecordEvent, opts}} <- ResourceInfo.changes(@resource), do: opts

    assert Enum.map(opts[:emits], & &1.signal) == @state_signals
  end

  test "persists the signals module as one the resource emits to" do
    assert Extension.get_persisted(@resource, :signals_out) == [AshWorkflowTest.Signals]
  end
end
