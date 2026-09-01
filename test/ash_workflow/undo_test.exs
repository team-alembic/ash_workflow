defmodule AshWorkflow.UndoTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Errors.UndoNotPermitted
  alias AshWorkflowTest.Reviewer
  alias AshWorkflowTest.SameActorUndoWorkflow
  alias AshWorkflowTest.UndoWorkflow

  defp rows(history) do
    Enum.map(history, &{&1.from_state, &1.to_state, &1.transition_name, &1.triggered_by})
  end

  defp reviewer(name) do
    Ash.create!(Reviewer, %{name: name}, action: :create)
  end

  defp approved(attrs \\ %{title: "test"}) do
    {:ok, record} = UndoWorkflow.create(attrs)
    Ash.update!(record, action: :approve)
  end

  describe "rewinding" do
    test "returns the record to the state before its last undoable transition" do
      record = approved()
      assert record.state == :publish

      undone = Ash.update!(record, action: :undo)

      assert undone.state == :review
    end

    test "appends a row rather than mutating the one it reverses" do
      record = approved()
      [_initial, approve_row] = UndoWorkflow.history(record)

      undone = Ash.update!(record, action: :undo)
      history = UndoWorkflow.history(undone)

      assert length(history) == 3
      assert Enum.at(history, 1).id == approve_row.id
      assert Enum.at(history, 1).to_state == :publish
      assert Enum.at(history, 1).triggered_by == :manual
    end

    test "the undo row points at the row it reverses" do
      record = approved()
      [_initial, approve_row] = UndoWorkflow.history(record)

      undone = Ash.update!(record, action: :undo)
      [_initial, _approve, undo_row] = UndoWorkflow.history(undone)

      assert undo_row.undoes_id == approve_row.id
      assert undo_row.triggered_by == :undo
      assert undo_row.from_state == :publish
      assert undo_row.to_state == :review
    end

    test "the undo row takes the name of the transition it reverses" do
      record = approved()
      undone = Ash.update!(record, action: :undo)

      assert List.last(UndoWorkflow.history(undone)).transition_name == :approve
    end

    test "resets the timer anchor so timeouts re-arm from the rewind" do
      record = approved()
      before_undo = record.state_entered_at

      undone = Ash.update!(record, action: :undo)

      assert DateTime.compare(undone.state_entered_at, before_undo) in [:gt, :eq]
    end
  end

  describe "conditional transitions" do
    test "rewinds whichever route was taken" do
      {:ok, record} = UndoWorkflow.create(%{title: "test", priority: :high})
      record = Ash.update!(record, action: :defer)
      record = Ash.update!(record, action: :resume)
      assert record.state == :publish

      undone = Ash.update!(record, action: :undo)

      assert undone.state == :deferred
    end
  end

  describe "repeating timeouts" do
    test "same-state rows are not what undo reverses" do
      {:ok, record} = UndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :defer)
      record = Ash.update!(record, action: :send_nudge)

      assert {:deferred, :deferred, :send_nudge, :timeout} in rows(UndoWorkflow.history(record))

      undone = Ash.update!(record, action: :undo)

      assert undone.state == :review
      assert List.last(UndoWorkflow.history(undone)).transition_name == :defer
    end
  end

  describe "redo" do
    test "undoing an undo re-applies the transition" do
      record = approved()
      undone = Ash.update!(record, action: :undo)

      redone = Ash.update!(undone, action: :undo)

      assert redone.state == :publish
    end

    test "leaves the redo row standing in effective history" do
      record = approved()
      undone = Ash.update!(record, action: :undo)
      redone = Ash.update!(undone, action: :undo)

      assert rows(UndoWorkflow.history(redone, effective: true)) == [
               {nil, :review, :create, :initial},
               {:review, :publish, :approve, :undo}
             ]
    end
  end

  describe "effective history" do
    test "omits the reversed row while the full log keeps it" do
      record = approved()
      undone = Ash.update!(record, action: :undo)

      assert rows(UndoWorkflow.history(undone)) == [
               {nil, :review, :create, :initial},
               {:review, :publish, :approve, :manual},
               {:publish, :review, :approve, :undo}
             ]

      assert rows(UndoWorkflow.history(undone, effective: true)) == [
               {nil, :review, :create, :initial},
               {:publish, :review, :approve, :undo}
             ]
    end
  end

  describe "state_at/3" do
    test "reports the state the record really was in" do
      record = approved()
      at = List.last(UndoWorkflow.history(record)).occurred_at

      undone = Ash.update!(record, action: :undo)

      assert UndoWorkflow.state_at(undone, at) == :publish
    end

    test "ignores a state the record was rewound out of when effective" do
      record = approved()
      at = List.last(UndoWorkflow.history(record)).occurred_at

      undone = Ash.update!(record, action: :undo)

      assert UndoWorkflow.state_at(undone, at, effective: true) == :review
    end
  end

  describe "refusals" do
    test "a transition not marked undoable" do
      {:ok, record} = UndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :escalate)

      assert {:error, error} = Ash.update(record, action: :undo)
      assert %UndoNotPermitted{reason: :not_undoable} = hd(error.errors)
    end

    test "an automatic step's own transition" do
      record = approved()
      record = Ash.update!(record, action: :run_publish)
      assert record.state == :done

      assert {:error, error} = Ash.update(record, action: :undo)
      assert %UndoNotPermitted{reason: :not_undoable} = hd(error.errors)
    end

    test "a record that has not transitioned" do
      {:ok, record} = UndoWorkflow.create(%{title: "test"})

      assert {:error, error} = Ash.update(record, action: :undo)
      assert %UndoNotPermitted{reason: :no_history} = hd(error.errors)
    end

    test "a transition older than the configured window" do
      record = approved()
      [initial_row, approve_row] = UndoWorkflow.history(record)

      # Both rows move, so the approve stays the head of the log while ageing
      # past the one-hour window this workflow configures.
      Ash.update!(initial_row, %{occurred_at: DateTime.add(DateTime.utc_now(), -3, :hour)},
        action: :update
      )

      Ash.update!(approve_row, %{occurred_at: DateTime.add(DateTime.utc_now(), -2, :hour)},
        action: :update
      )

      assert {:error, error} = Ash.update(record, action: :undo)
      assert %UndoNotPermitted{reason: :window_expired} = hd(error.errors)
    end
  end

  describe "same_actor?" do
    test "permits the actor who made the transition" do
      actor = reviewer("ana")
      {:ok, record} = SameActorUndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :approve, actor: actor)

      undone = Ash.update!(record, action: :undo, actor: actor)

      assert undone.state == :review
    end

    test "refuses a different actor" do
      actor = reviewer("ana")
      other = reviewer("bo")
      {:ok, record} = SameActorUndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :approve, actor: actor)

      assert {:error, error} = Ash.update(record, action: :undo, actor: other)
      assert %UndoNotPermitted{reason: :different_actor} = hd(error.errors)
    end

    test "refuses when the caller has no actor" do
      actor = reviewer("ana")
      {:ok, record} = SameActorUndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :approve, actor: actor)

      assert {:error, error} = Ash.update(record, action: :undo)
      assert %UndoNotPermitted{reason: :no_actor} = hd(error.errors)
    end

    test "refuses when the transition recorded no actor" do
      {:ok, record} = SameActorUndoWorkflow.create(%{title: "test"})
      record = Ash.update!(record, action: :approve)

      assert {:error, error} = Ash.update(record, action: :undo, actor: reviewer("ana"))
      assert %UndoNotPermitted{reason: :no_actor} = hd(error.errors)
    end
  end

  describe "the concurrency guard" do
    # The window it closes — a forward transition landing between the log read
    # and the write — cannot be produced deterministically from the public API,
    # so this asserts the guard is attached rather than trying to race it.
    test "filters the write on the state the log said the record was in" do
      record = approved()

      guarded =
        record
        |> Ash.Changeset.for_update(:undo, %{})
        |> then(fn changeset ->
          Enum.reduce(changeset.before_action, changeset, & &1.(&2))
        end)

      assert inspect(guarded.filter) =~ "state == :publish"
    end
  end

  describe "undoable?/2 and undo_target/2" do
    test "answer without writing" do
      record = approved()

      assert UndoWorkflow.undoable?(record)
      assert UndoWorkflow.undo_target(record) == :review
      assert length(UndoWorkflow.history(record)) == 2
    end

    test "report a refusal as false and nil" do
      {:ok, record} = UndoWorkflow.create(%{title: "test"})

      refute UndoWorkflow.undoable?(record)
      assert UndoWorkflow.undo_target(record) == nil
    end
  end

  describe "introspection" do
    test "undoable_edges lists one edge per undoable target" do
      assert Enum.sort(AshWorkflow.Info.undoable_edges(UndoWorkflow)) ==
               Enum.sort([
                 {:review, :publish},
                 {:review, :deferred},
                 {:deferred, :review},
                 {:deferred, :publish}
               ])
    end

    test "no edges without an undo block" do
      assert AshWorkflow.Info.undoable_edges(AshWorkflowTest.LoggedWorkflow) == []
    end

    test "the state machine permits both directions of every undoable edge" do
      undo_transitions =
        UndoWorkflow
        |> AshStateMachine.Info.state_machine_transitions()
        |> Enum.filter(&(&1.action == :undo))
        |> Enum.flat_map(fn transition ->
          for from <- transition.from, to <- transition.to, do: {from, to}
        end)

      assert {:publish, :review} in undo_transitions
      assert {:review, :publish} in undo_transitions
      assert {:deferred, :review} in undo_transitions
      assert {:review, :deferred} in undo_transitions
    end
  end
end
