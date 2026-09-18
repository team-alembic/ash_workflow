defmodule AshWorkflow.TransitionLogTest do
  use ExUnit.Case, async: true

  alias AshWorkflowTest.LoggedWorkflow
  alias AshWorkflowTest.Reviewer

  defp names(history) do
    Enum.map(history, &{&1.from_state, &1.to_state, &1.transition_name, &1.triggered_by})
  end

  describe "the :initial row" do
    test "is written on create, with a nil from_state" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})

      assert [row] = LoggedWorkflow.history(record)
      assert row.from_state == nil
      assert row.to_state == :intake
      assert row.transition_name == :create
      assert row.triggered_by == :initial
    end
  end

  describe "manual transitions" do
    test "write a row with triggered_by: :manual" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :approve)

      assert names(LoggedWorkflow.history(record)) == [
               {nil, :intake, :create, :initial},
               {:intake, :review, :process_intake, :automatic},
               {:review, :done, :approve, :manual}
             ]
    end
  end

  describe "automatic steps" do
    test "success writes a row with triggered_by: :automatic" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)

      assert [_initial, success] = LoggedWorkflow.history(record)
      assert success.from_state == :intake
      assert success.to_state == :review
      assert success.triggered_by == :automatic
    end

    test "the on_error path writes a row with triggered_by: :error_path" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :__on_error_intake)

      assert [_initial, error_row] = LoggedWorkflow.history(record)
      assert error_row.from_state == :intake
      assert error_row.to_state == :failed
      assert error_row.triggered_by == :error_path
    end
  end

  describe "timeouts" do
    test "a transitioning timeout writes a row with triggered_by: :timeout" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :__timeout_review_escalation)

      assert [_initial, _automatic, escalation] = LoggedWorkflow.history(record)
      assert escalation.from_state == :review
      assert escalation.to_state == :escalated
      assert escalation.triggered_by == :timeout
    end

    test "an every writes a from_state == to_state row" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :send_reminder)

      assert [_initial, _automatic, reminder] = LoggedWorkflow.history(record)
      assert reminder.from_state == :review
      assert reminder.to_state == :review
      assert reminder.triggered_by == :timeout
    end

    test "a non-repeating action timeout writes a from_state == to_state row" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :send_nudge)

      assert [_initial, _automatic, nudge] = LoggedWorkflow.history(record)
      assert nudge.from_state == :review
      assert nudge.to_state == :review
      assert nudge.transition_name == :send_nudge
      assert nudge.triggered_by == :timeout
    end

    test "a non-repeating action timeout leaves state_entered_at where it was" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      entered_review_at = record.state_entered_at

      {:ok, record} = Ash.update(record, action: :send_nudge)

      assert record.state_entered_at == entered_review_at
    end

    test "an every resets state_entered_at to re-arm its trigger" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      entered_review_at = record.state_entered_at

      {:ok, record} = Ash.update(record, action: :send_reminder)

      assert DateTime.after?(record.state_entered_at, entered_review_at)
    end

    test "firing an every twice writes two from_state == to_state rows" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :send_reminder)
      {:ok, record} = Ash.update(record, action: :send_reminder)

      fired_twice =
        record
        |> LoggedWorkflow.history()
        |> Enum.filter(&(&1.from_state == :review and &1.to_state == :review))

      assert length(fired_twice) == 2
    end
  end

  describe "history/1" do
    test "returns rows ordered by occurred_at ascending" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :approve)

      occurred_ats = record |> LoggedWorkflow.history() |> Enum.map(& &1.occurred_at)

      assert occurred_ats == Enum.sort(occurred_ats, DateTime)
    end
  end

  describe "state_at/2" do
    test "returns nil before the earliest logged row" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      before_creation = DateTime.add(DateTime.utc_now(), -1, :day)

      assert LoggedWorkflow.state_at(record, before_creation) == nil
    end

    test "returns the state that was active at a point in time" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      [initial_row] = LoggedWorkflow.history(record)

      {:ok, record} = Ash.update(record, action: :process_intake)
      [_initial, automatic_row] = LoggedWorkflow.history(record)

      {:ok, record} = Ash.update(record, action: :approve)

      assert LoggedWorkflow.state_at(record, initial_row.occurred_at) == :intake
      assert LoggedWorkflow.state_at(record, automatic_row.occurred_at) == :review
    end

    test "returns the current state at or after the last logged row" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)
      {:ok, record} = Ash.update(record, action: :approve)

      after_everything = DateTime.add(DateTime.utc_now(), 1, :day)

      assert LoggedWorkflow.state_at(record, after_everything) == :done
    end
  end

  describe "entered_current_state_at vs state_entered_at" do
    test "entered_current_state_at ignores every rows, state_entered_at does not" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})
      {:ok, record} = Ash.update(record, action: :process_intake)

      loaded = Ash.load!(record, [:entered_current_state_at, :state_entered_at])
      entered_review_at = loaded.entered_current_state_at
      state_entered_at_after_automatic = loaded.state_entered_at

      {:ok, record} = Ash.update(record, action: :send_reminder)
      loaded = Ash.load!(record, [:entered_current_state_at, :state_entered_at])

      assert loaded.entered_current_state_at == entered_review_at
      assert loaded.state_entered_at != state_entered_at_after_automatic
    end
  end

  describe "belongs_to_actor" do
    test "records the actor on the log row when present" do
      {:ok, reviewer} = Reviewer.create(%{name: "Alice"})

      record =
        LoggedWorkflow
        |> Ash.Changeset.for_create(:create, %{title: "test"}, actor: reviewer)
        |> Ash.create!()

      {:ok, record} = Ash.update(record, action: :process_intake, actor: reviewer)
      {:ok, record} = Ash.update(record, action: :approve, actor: reviewer)

      history = LoggedWorkflow.history(record)
      assert Enum.all?(history, &(&1.user_id == reviewer.id))
    end

    test "leaves the actor attribute nil when no actor is given" do
      {:ok, record} = LoggedWorkflow.create(%{title: "test"})

      assert [row] = LoggedWorkflow.history(record)
      assert row.user_id == nil
    end
  end
end
