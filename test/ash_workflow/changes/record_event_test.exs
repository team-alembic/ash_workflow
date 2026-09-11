defmodule AshWorkflow.Changes.RecordEventTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias Ash.Resource.Change.Context
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Changes.RecordEvent
  alias AshWorkflowTest.LoggedWorkflow
  alias AshWorkflowTest.SharedTimeoutNameWorkflow

  describe "injection onto action timeouts" do
    test "a non-repeating action timeout gets RecordEvent" do
      assert [{RecordEvent, triggered_by: :timeout}] ==
               change_specs(LoggedWorkflow, :send_nudge)
    end

    test "a repeating action timeout gets RecordEvent" do
      assert [{RecordEvent, triggered_by: :timeout}] ==
               change_specs(LoggedWorkflow, :send_reminder)
    end

    test "two timeouts naming the same action get one RecordEvent between them" do
      assert [{RecordEvent, triggered_by: :timeout}] ==
               change_specs(SharedTimeoutNameWorkflow, :send_warning)
    end

    defp change_specs(resource, action_name) do
      resource
      |> ResourceInfo.action(action_name)
      |> Map.get(:changes)
      |> Enum.map(& &1.change)
    end
  end

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

  describe "from_state on the atomic path" do
    # An atomic update acts on a query, so the changeset has no `data` holding
    # the pre-update state. AshOban drives every automatic step and timeout that
    # way, so this is the common case, not the exotic one — and a nil from_state
    # is indistinguishable from the legitimately-nil `:initial` row.
    defp atomically(record, action) do
      LoggedWorkflow
      |> Ash.Query.do_filter(id: record.id)
      |> Ash.bulk_update!(action, %{}, strategy: :atomic, return_errors?: true)

      Ash.get!(LoggedWorkflow, record.id)
    end

    defp last_event(record), do: record |> LoggedWorkflow.history() |> List.last()

    test "an atomic transition records the state it left" do
      {:ok, record} = LoggedWorkflow.create(%{title: "atomic from_state"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      assert record.state == :review

      record = atomically(record, :approve)

      assert record.state == :done
      assert last_event(record).from_state == :review
    end

    test "a non-atomic transition still records the state it left" do
      {:ok, record} = LoggedWorkflow.create(%{title: "non-atomic from_state"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :approve)

      assert last_event(record).from_state == :review
    end

    test "every row but the first has a from_state, driving only atomic updates" do
      {:ok, record} = LoggedWorkflow.create(%{title: "all atomic"})
      record = atomically(record, :process_intake)
      record = atomically(record, :approve)

      [initial | rest] = LoggedWorkflow.history(record)

      assert initial.from_state == nil, "the :initial row has nothing to have come from"
      assert rest != []

      for event <- rest do
        assert event.from_state != nil,
               "#{inspect(event.transition_name)} logged a nil from_state, which reads as an :initial row"
      end
    end

    test "each row's from_state is the previous row's to_state" do
      {:ok, record} = LoggedWorkflow.create(%{title: "chain"})
      record = atomically(record, :process_intake)
      record = atomically(record, :approve)

      history = LoggedWorkflow.history(record)

      history
      |> Enum.zip(tl(history))
      |> Enum.each(fn {previous, current} ->
        assert current.from_state == previous.to_state
      end)
    end

    test "the create row keeps a nil from_state" do
      {:ok, record} = LoggedWorkflow.create(%{title: "create row"})

      assert [%{from_state: nil, triggered_by: :initial}] = LoggedWorkflow.history(record)
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
