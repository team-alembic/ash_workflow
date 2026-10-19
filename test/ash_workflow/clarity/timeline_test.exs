defmodule AshWorkflow.Clarity.TimelineTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Clarity.Timeline

  defp moments(resource, step) do
    for moment <- Timeline.step(resource, step).moments do
      {moment.label, Enum.map(moment.events, & &1.text)}
    end
  end

  describe "step/2" do
    test "an automatic step runs on entry, then lists each retry at its backoff" do
      assert moments(AshWorkflowTest.RetryWorkflow, :fixed_backoff) == [
               {"on entry",
                [
                  "step_b runs at the next poll, within 1 minute",
                  "when it succeeds the record moves to default_backoff"
                ]},
               {"after 10 seconds", ["attempt 2 of 3 if attempt 1 failed"]},
               {"after 20 seconds",
                [
                  "attempt 3 of 3 if attempt 2 failed",
                  "if every attempt fails the record moves to failed"
                ]}
             ]
    end

    test "an exponential backoff follows Oban's formula" do
      offsets =
        for moment <- Timeline.step(AshWorkflowTest.RetryWorkflow, :default_backoff).moments,
            do: moment.label

      assert offsets == [
               "on entry",
               "after 16 seconds",
               "after 47 seconds",
               "after 2 minutes 23 seconds",
               "after 6 minutes 54 seconds"
             ]
    end

    test "a precise scheduler has no lag" do
      timeline = Timeline.step(AshWorkflowTest.PreciseRetryWorkflow, :processing)

      assert timeline.lag == nil

      assert {"on entry", ["process runs" | _]} =
               hd(moments(AshWorkflowTest.PreciseRetryWorkflow, :processing))

      assert timeline.leaves_by == {:offset, 1_000}
    end

    test "a timeout that runs an action names its retry policy" do
      assert {"after 2 days", ["nudge runs send_nudge, retried as 2 attempts, 30 seconds apart"]} in moments(
               AshWorkflowTest.RetryWorkflow,
               :waiting
             )
    end

    test "a bounded every fires until its until, then stops" do
      assert moments(AshWorkflowTest.EveryUntilWorkflow, :waiting) == [
               {"on entry", ["callers can run resolve"]},
               {"after 1 hour", ["reminder runs send_reminder"]},
               {"after 2 hours", ["reminder runs send_reminder"]},
               {"after 3 hours", ["reminder stops"]}
             ]
    end

    test "an every stops at the timeout that moves the record on" do
      timeline = Timeline.step(BasicWorkflow.Incident, :investigating)

      assert Enum.map(timeline.moments, & &1.label) ==
               ["on entry", "after 1 hour", "after 2 hours", "after 3 hours", "after 4 hours"]

      assert timeline.leaves_by == {:offset, 4 * 3_600_000}
    end

    test "an unbounded every lists its first firings, then the interval" do
      assert {"after 9 days", ["dunning_email runs send_dunning_email, and every 3 days after"]} in moments(
               BasicWorkflow.Subscription,
               :grace_period
             )
    end

    test "a deadline read from a field follows the fixed moments" do
      assert [{"on entry", _}, {"3 days after last_session_date", [text]}] =
               moments(AshWorkflowTest.FieldTimeoutWorkflow, :active)

      assert text ==
               "inactivity moves the record to inactive_review, after which deactivate can no longer run"
    end

    test "a fire_at deadline is the step's exit" do
      timeline = Timeline.step(AshWorkflowTest.FireAtWorkflow, :waiting)

      assert timeline.leaves_by == {:anchor, "at next_check_at"}
    end

    test "undo opens on entering the step and closes at its window" do
      assert moments(BasicWorkflow.Incident, :escalated) == [
               {"on entry",
                ["callers can run resolve", "undo can return the record to investigating"]},
               {"after 1 hour", ["the undo window closes"]}
             ]
    end

    test "a step with only transitions waits for a caller" do
      assert Timeline.step(BasicWorkflow.Subscription, :active).leaves_by == :caller
    end

    test "a terminal step ends the workflow" do
      timeline = Timeline.step(BasicWorkflow.Subscription, :cancelled)

      assert timeline.leaves_by == :never
      assert Enum.map(timeline.moments, & &1.label) == ["on entry"]
    end
  end

  describe "leaves_by_text/2" do
    defp leaves(resource, step_name) do
      Timeline.leaves_by_text(
        Timeline.step(resource, step_name),
        AshWorkflow.Info.step(resource, step_name)
      )
    end

    test "a manual step with a timeout leaves by the deadline, or sooner on a transition" do
      assert leaves(BasicWorkflow.Incident, :investigating) ==
               "within 4 hours, up to 1 minute more, or sooner when a caller runs a transition"

      assert leaves(AshWorkflowTest.FireAtWorkflow, :waiting) ==
               "by next_check_at, or sooner when a caller runs a transition"
    end

    test "an automatic step leaves when its action finishes, or once retries run out" do
      assert leaves(AshWorkflowTest.RetryWorkflow, :fixed_backoff) ==
               "when step_b finishes (it starts within 1 minute), or 20 seconds later once retries run out"
    end
  end

  describe "humanize/1" do
    test "keeps the two largest units" do
      assert Timeline.humanize(1_000) == "1 second"
      assert Timeline.humanize(90_000) == "1 minute 30 seconds"
      assert Timeline.humanize(90_061_000) == "1 day 1 hour"
    end
  end
end
