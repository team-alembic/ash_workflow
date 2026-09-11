defmodule AshWorkflow.SchedulerTest do
  @moduledoc """
  The scheduler behaviour is what lets a workflow's deadlines be run by
  something other than Oban. These tests assert the surface is described in
  AshWorkflow's own vocabulary — steps, timeouts, deadlines — so an
  implementation needs no understanding of ash_oban, and that a resource whose
  scheduler is not Oban does not carry the ash_oban DSL at all.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  alias AshWorkflow.Scheduler.Work
  alias AshWorkflowTest.CustomSchedulerWorkflow
  alias AshWorkflowTest.TestScheduler

  defp works, do: TestScheduler.works(CustomSchedulerWorkflow)

  defp work(name), do: Enum.find(works(), &(&1.name == name))

  describe "selecting a scheduler" do
    test "defaults to the Oban implementation" do
      assert {AshWorkflow.Scheduler.Oban, []} =
               AshWorkflow.Info.scheduler(AshWorkflowTest.TimeoutWorkflow)
    end

    test "a resource may name its own, with options" do
      assert {TestScheduler, [precision: :high]} =
               AshWorkflow.Info.scheduler(CustomSchedulerWorkflow)
    end

    test "the options reach the implementation" do
      assert TestScheduler.opts(CustomSchedulerWorkflow) == [precision: :high]
    end

    test "a bare module is accepted as well as a tuple" do
      assert AshWorkflow.Scheduler.validate(TestScheduler) == {:ok, {TestScheduler, []}}
    end

    test "rejects options that are not a keyword list" do
      assert {:error, message} = AshWorkflow.Scheduler.validate({TestScheduler, [1, 2]})
      assert message =~ "keyword list"
    end
  end

  describe "a scheduler that is not Oban" do
    test "needs no AshOban extension" do
      refute AshOban in Spark.extensions(CustomSchedulerWorkflow)
    end

    test "and so generates no triggers" do
      assert AshOban.Info.oban_triggers(CustomSchedulerWorkflow) == []
    end
  end

  describe "the work handed to a scheduler" do
    test "covers every automatic step and every timeout, and nothing else" do
      assert Enum.map(works(), & &1.name) |> Enum.sort() == [
               :__timeout_trigger_review_escalate,
               :__timeout_trigger_review_nudge,
               :processing
             ]
    end

    test "describes an automatic step as eligible whenever a record occupies it" do
      work = work(:processing)

      assert work.kind == :step
      assert work.action == :process
      assert work.step == :processing
      # No deadline: the record being in the step is the whole condition.
      assert work.deadline == nil
    end

    test "routes a step's failure to its error path" do
      assert work(:processing).on_error == :__on_error_processing
    end

    test "gives a timeout both a match expression and a deadline rule" do
      work = work(:__timeout_trigger_review_escalate)

      assert work.kind == :timeout
      assert work.step == :review
      assert work.timeout == :escalate
      assert work.deadline == %{field: :state_entered_at, fire_after: {7, :days}}
      assert work.match
    end

    test "names the generated action for a transition timeout" do
      assert work(:__timeout_trigger_review_escalate).action == :__timeout_review_escalate
    end

    test "names the user's own action for an action timeout" do
      assert work(:__timeout_trigger_review_nudge).action == :send_nudge
    end

    test "marks an action timeout as firing once, since it does not change state" do
      assert work(:__timeout_trigger_review_nudge).once?
      refute work(:__timeout_trigger_review_escalate).once?
    end

    test "carries the resource, so an implementation can query it" do
      assert Enum.all?(works(), &(&1.resource == CustomSchedulerWorkflow))
    end
  end

  describe "due_at/2" do
    test "computes the instant from the deadline's field and duration" do
      record = %{state_entered_at: ~U[2026-01-01 00:00:00.000000Z]}

      assert AshWorkflow.Scheduler.due_at(work(:__timeout_trigger_review_escalate), record) ==
               ~U[2026-01-08 00:00:00.000000Z]
    end

    test "is nil for work with no deadline" do
      assert AshWorkflow.Scheduler.due_at(work(:processing), %{}) == nil
    end

    test "is nil when the deadline's field has no value on the record" do
      assert AshWorkflow.Scheduler.due_at(
               work(:__timeout_trigger_review_escalate),
               %{state_entered_at: nil}
             ) == nil
    end
  end

  describe "the Oban implementation" do
    test "rejects a resource that has not added the AshOban extension" do
      assert_dsl_error(
        """
        defmodule MissingAshOban do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            step :review do
              transition :approve, to: :approved
              timeout :escalate, fire_after: {2, :days}, transition_to: :escalated
            end

            step :approved, terminal: true
            step :escalated, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/does not have the AshOban extension/
      )
    end

    test "keeps trigger and worker module names, so enqueued jobs still resolve" do
      trigger =
        AshWorkflowTest.TimeoutWorkflow
        |> AshOban.Info.oban_triggers()
        |> Enum.find(&(&1.name == :__timeout_trigger_waiting_reminder))

      assert trigger.worker ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Workers.Timeouts.Waiting.Reminder

      assert trigger.scheduler ==
               AshWorkflowTest.TimeoutWorkflow.AshWorkflow.Schedulers.Timeouts.Waiting.Reminder
    end
  end

  defmodule NoOpScheduler do
    @moduledoc false
    use AshWorkflow.Scheduler
  end

  describe "use AshWorkflow.Scheduler" do
    test "supplies a transform that adds nothing" do
      assert NoOpScheduler.transform(:dsl, [%Work{}], []) == {:ok, :dsl}
    end
  end
end
