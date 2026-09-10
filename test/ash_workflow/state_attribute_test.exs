defmodule AshWorkflow.StateAttributeTest do
  @moduledoc """
  Covers a workflow whose state lives in `status` rather than `state`.

  Everything AshWorkflow generates has to read the attribute the resource
  actually declared: the state machine, the generated actions, the Oban
  trigger filters, the calculations, the recommended indexes, and the
  transition log.
  """

  use ExUnit.Case, async: true

  require Ash.Query

  alias AshWorkflow.Info

  @workflow AshWorkflowTest.StatusWorkflow

  defp create!(attrs \\ %{}) do
    AshWorkflowTest.StatusWorkflow.create!(Map.merge(%{title: "test"}, attrs))
  end

  # The escalation timeout is measured from `state_entered_at`, so a record
  # only crosses the deadline by having entered its step long enough ago.
  defp backdate!(record, days_ago) do
    record
    |> Ash.Changeset.for_update(:touch, %{})
    |> Ash.Changeset.force_change_attribute(
      :state_entered_at,
      DateTime.add(DateTime.utc_now(), -days_ago, :day)
    )
    |> Ash.update!()
  end

  defp trigger(name) do
    @workflow
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == name))
  end

  defp matching_ids(trigger) do
    @workflow
    |> Ash.Query.do_filter(trigger.where)
    |> Ash.read!()
    |> Map.get(:results)
    |> Enum.map(& &1.id)
  end

  describe "the state_attribute option" do
    test "Info.state_attribute/1 returns the configured attribute" do
      assert Info.state_attribute(@workflow) == :status
    end

    test "Info.state_attribute/1 defaults to :state" do
      assert Info.state_attribute(AshWorkflowTest.ApprovalWorkflow) == :state
    end

    test "is passed down to ash_state_machine" do
      assert AshStateMachine.Info.state_machine_state_attribute!(@workflow) == :status
    end

    test "the state machine still knows the workflow's steps" do
      assert AshStateMachine.Info.state_machine_initial_states!(@workflow) == [:intake]
      assert :review in AshStateMachine.Info.state_machine_all_states(@workflow)
    end

    test "the resource has a status attribute and no state attribute" do
      assert Ash.Resource.Info.attribute(@workflow, :status)
      refute Ash.Resource.Info.attribute(@workflow, :state)
    end

    test "state_entered_at is still added under its own name" do
      assert Ash.Resource.Info.attribute(@workflow, :state_entered_at)
    end
  end

  describe "generated actions" do
    test "a record starts in the initial step" do
      assert create!().status == :intake
    end

    test "an automatic step transitions on success" do
      record = create!() |> Ash.update!(action: :process_intake)

      assert record.status == :review
    end

    test "a manual transition moves the record" do
      record =
        create!()
        |> Ash.update!(action: :process_intake)
        |> Ash.update!(action: :approve)

      assert record.status == :published
    end

    test "a conditional transition takes the route matching the record" do
      record =
        create!(%{priority: :high})
        |> Ash.update!(action: :process_intake)
        |> Ash.update!(action: :triage)

      assert record.status == :published
    end

    test "a conditional transition takes the other route" do
      record =
        create!(%{priority: :normal})
        |> Ash.update!(action: :process_intake)
        |> Ash.update!(action: :triage)

      assert record.status == :rejected
    end

    test "the attribute records when the step was entered" do
      record = create!() |> Ash.update!(action: :process_intake)

      assert %DateTime{} = record.state_entered_at
    end
  end

  describe "oban triggers" do
    test "an automatic step trigger matches records in that step" do
      record = create!()

      assert record.id in matching_ids(trigger(:intake))
    end

    test "an automatic step trigger skips records that have left the step" do
      record = create!() |> Ash.update!(action: :process_intake)

      refute record.id in matching_ids(trigger(:intake))
    end

    test "a timeout trigger filters on the renamed attribute" do
      record = create!() |> Ash.update!(action: :process_intake)

      # Not due yet: the filter has to match on the step and miss on the clock.
      refute record.id in matching_ids(trigger(:__timeout_trigger_review_escalation))

      overdue = backdate!(record, 8)

      assert overdue.id in matching_ids(trigger(:__timeout_trigger_review_escalation))
    end
  end

  describe "calculations" do
    test "current_step reads the renamed attribute" do
      record = create!() |> Ash.update!(action: :process_intake) |> Ash.load!(:current_step)

      assert record.current_step == :review
    end

    test "available_actions reads the renamed attribute" do
      record = create!() |> Ash.update!(action: :process_intake) |> Ash.load!(:available_actions)

      assert record.available_actions == [:approve, :triage]
    end

    test "pending_deadlines reads the renamed attribute" do
      record = create!() |> Ash.update!(action: :process_intake) |> Ash.load!(:pending_deadlines)

      assert [%{name: :escalation, target: :escalated}] = record.pending_deadlines
    end
  end

  describe "recommended indexes" do
    test "lead with the renamed attribute" do
      assert Info.recommended_indexes(@workflow) == [[:status, :state_entered_at]]
    end
  end

  describe "transition log" do
    test "records the states the renamed attribute moved through" do
      record = create!() |> Ash.update!(action: :process_intake) |> Ash.update!(action: :approve)

      rows =
        AshWorkflowTest.StatusLog
        |> Ash.Query.filter(workflow_id == ^record.id)
        |> Ash.Query.sort(occurred_at: :asc)
        |> Ash.read!()
        |> Enum.map(&{&1.from_state, &1.to_state})

      assert rows == [{nil, :intake}, {:intake, :review}, {:review, :published}]
    end
  end
end
