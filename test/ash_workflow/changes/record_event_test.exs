defmodule AshWorkflow.Changes.RecordEventTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Change.Context
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Changes.RecordEvent
  alias AshWorkflowTest.LoggedWorkflow

  describe "atomicity" do
    test "manual transition actions stay require_atomic?: true — RecordEvent does not force an opt-out" do
      action = ResourceInfo.action(LoggedWorkflow, :approve)
      assert action.require_atomic? == true
    end

    test "the automatic step's action stays require_atomic?: true" do
      action = ResourceInfo.action(LoggedWorkflow, :process_intake)
      assert action.require_atomic? == true
    end

    test "atomic/3 returns an atomic state_entered_at expression and a modified changeset" do
      changeset =
        LoggedWorkflow
        |> Ash.Changeset.for_create(:create, %{title: "atomic test"})
        |> Map.put(:action_type, :update)
        |> Map.put(:data, %LoggedWorkflow{state: :intake})

      context = %Context{actor: nil}

      assert {:atomic, %Ash.Changeset{} = returned_changeset, atomics} =
               RecordEvent.atomic(changeset, [triggered_by: :manual], context)

      assert %{state_entered_at: _now_expr} = atomics
      assert returned_changeset.after_action != []
    end

    test "an action whose action runs atomically still writes through the log" do
      {:ok, record} = LoggedWorkflow.create(%{title: "atomic write-through"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :approve)

      assert record.state == :done

      history = LoggedWorkflow.history(record)
      assert length(history) == 3
      assert Enum.all?(history, & &1.occurred_at)
    end
  end

  describe "init/1" do
    test "accepts a valid triggered_by" do
      assert {:ok, _opts} = RecordEvent.init(triggered_by: :manual)
    end

    test "rejects an invalid triggered_by" do
      assert {:error, message} = RecordEvent.init(triggered_by: :bogus)
      assert message =~ "triggered_by"
    end
  end
end
