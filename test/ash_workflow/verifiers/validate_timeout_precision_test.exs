defmodule AshWorkflow.Verifiers.ValidateTimeoutPrecisionTest do
  @moduledoc """
  Timeouts fire when a cron scheduler next notices the deadline has passed, and
  cron cannot poll below one minute. A sub-minute deadline is therefore a
  promise the scheduler cannot keep, and the DSL refuses it rather than firing
  up to 60 seconds late.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  defp workflow(name, timeout_body) do
    """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow, AshOban]

      workflow do
        step :waiting do
          transition :resolve, to: :done

          #{timeout_body}
        end

        step :done, terminal: true
        step :escalated, terminal: true
      end

      actions do
        update :send_reminder do
          accept []
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :title, :string, allow_nil?: false, public?: true
        attribute :deadline_at, :utc_datetime_usec, public?: true
      end
    end
    """
  end

  describe "rejects deadlines shorter than the polling floor" do
    test "a duration in seconds" do
      assert_dsl_error(
        workflow(
          "SubMinuteSeconds",
          "timeout :nudge, after: {30, :seconds}, action: :send_reminder"
        ),
        ~r/which is shorter than AshWorkflow.Scheduler.Oban can honour/
      )
    end

    test "the smallest possible duration" do
      assert_dsl_error(
        workflow("OneSecond", "timeout :nudge, after: {1, :seconds}, action: :send_reminder"),
        ~r/checks no more often than every 1m/
      )
    end

    test "a sub-minute duration measured against a custom field" do
      assert_dsl_error(
        workflow(
          "SubMinuteCustomField",
          "timeout :nudge, after: {1, :seconds}, field: :deadline_at, action: :send_reminder"
        ),
        ~r/which is shorter than AshWorkflow.Scheduler.Oban can honour/
      )
    end

    test "a forced transition, not only an action" do
      assert_dsl_error(
        workflow(
          "SubMinuteTransition",
          "timeout :nudge, after: {5, :seconds}, transition_to: :escalated"
        ),
        ~r/which is shorter than AshWorkflow.Scheduler.Oban can honour/
      )
    end

    test "and names both ways out" do
      assert_dsl_error(
        workflow(
          "SubMinuteGuidance",
          "timeout :nudge, after: {5, :seconds}, action: :send_reminder"
        ),
        ~r/after: \{1, :minutes\}/
      )

      assert_dsl_error(
        workflow(
          "SubMinuteGuidance2",
          "timeout :nudge, after: {5, :seconds}, action: :send_reminder"
        ),
        ~r/self_scheduled\?: true/
      )
    end
  end

  describe "the floor comes from the selected scheduler" do
    test "names selecting a precise scheduler as a way out" do
      assert_dsl_error(
        workflow(
          "SubMinuteNamesPrecise",
          "timeout :nudge, after: {5, :seconds}, action: :send_reminder"
        ),
        ~r/scheduler AshWorkflow.Scheduler.Precise/
      )
    end

    test "a sub-minute deadline is accepted under Precise, with no self_scheduled? flag" do
      assert AshWorkflowTest.PreciseTimeoutWorkflow.__info__(:module) ==
               AshWorkflowTest.PreciseTimeoutWorkflow

      timeout =
        AshWorkflowTest.PreciseTimeoutWorkflow
        |> AshWorkflow.Info.steps()
        |> Enum.find(&(&1.name == :waiting))
        |> Map.fetch!(:timeouts)
        |> Enum.find(&(&1.name == :nudge))

      assert timeout.after == {5, :seconds}
      refute timeout.self_scheduled?
    end
  end

  describe "accepts deadlines the scheduler can honour" do
    test "exactly one minute" do
      assert AshWorkflowTest.OneMinuteWorkflow.__info__(:module) ==
               AshWorkflowTest.OneMinuteWorkflow
    end

    test "sixty seconds, which is the same instant spelled differently" do
      assert AshWorkflowTest.SixtySecondsWorkflow.__info__(:module) ==
               AshWorkflowTest.SixtySecondsWorkflow
    end

    test "a sub-minute deadline that declares itself self-scheduled" do
      assert AshWorkflowTest.CheckIntervalWorkflow.__info__(:module) ==
               AshWorkflowTest.CheckIntervalWorkflow
    end
  end

  describe "self_scheduled?" do
    defp trigger_for(resource, trigger_name) do
      resource
      |> AshOban.Info.oban_triggers()
      |> Enum.find(&(&1.name == trigger_name))
    end

    test "changes nothing about what is generated" do
      # The claim is about who runs the trigger, not about what exists. The
      # scheduler and its cron must survive, or AshOban.schedule/2 and
      # schedule_and_run_triggers/1 could not drive it — which is the whole
      # point of saying you will drive it yourself.
      trigger =
        trigger_for(
          AshWorkflowTest.CheckIntervalWorkflow,
          :__timeout_trigger_waiting_self_scheduled
        )

      assert trigger.scheduler_cron == "0 * * * *"
      assert trigger.scheduler
    end
  end
end
