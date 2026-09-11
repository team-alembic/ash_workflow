defmodule AshWorkflow.RetryTest do
  @moduledoc """
  A `retry` block is the failure policy for a step's or a timeout's generated
  work, and every scheduler needs to see the same policy through its own
  vocabulary. `AshWorkflow.Scheduler.Oban` turns it into a trigger's
  `max_attempts` and `backoff`, and `AshWorkflow.Info.scheduled_work/1` carries
  it as an `AshWorkflow.Entities.Retry` struct on the matching `Work` — these
  tests check both come out right, including the defaults for a step or
  timeout that declares no `retry` block at all.
  """
  use ExUnit.Case, async: true

  alias AshWorkflow.Entities.Retry
  alias AshWorkflowTest.RetryWorkflow

  defp trigger(name) do
    RetryWorkflow
    |> AshOban.Info.oban_triggers()
    |> Enum.find(&(&1.name == name))
  end

  defp work(name) do
    RetryWorkflow
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.find(&(&1.name == name))
  end

  # `Retry` carries Spark's own compile-time metadata alongside the fields the
  # DSL author wrote, so comparing structs for equality asserts on the two
  # fields that matter rather than on where the block was declared.
  defp retry(work), do: %{work.retry | __spark_metadata__: nil}

  describe "generated triggers" do
    test "a step with no retry block gets max_attempts: 1 and the default backoff" do
      trigger = trigger(:no_retry)

      assert trigger.max_attempts == 1
      assert trigger.backoff == :exponential
    end

    test "a step with a fixed backoff carries both onto the trigger, converted to seconds" do
      trigger = trigger(:fixed_backoff)

      assert trigger.max_attempts == 3
      assert trigger.backoff == 10
    end

    test "a step that only declares max_attempts keeps the default exponential backoff" do
      trigger = trigger(:default_backoff)

      assert trigger.max_attempts == 5
      assert trigger.backoff == :exponential
    end

    test "a timeout's own retry block reaches its trigger the same way" do
      trigger = trigger(:__timeout_trigger_waiting_nudge)

      assert trigger.max_attempts == 2
      assert trigger.backoff == 30
    end
  end

  describe "scheduled_work" do
    test "a step with no retry block carries the default Retry struct" do
      assert retry(work(:no_retry)) == %Retry{}
    end

    test "a step with a fixed backoff carries the declared Retry struct" do
      assert retry(work(:fixed_backoff)) == %Retry{max_attempts: 3, backoff: {10, :seconds}}
    end

    test "a step with only max_attempts carries the default backoff" do
      assert retry(work(:default_backoff)) == %Retry{max_attempts: 5, backoff: :exponential}
    end

    test "a timeout's retry block carries onto its own Work" do
      assert retry(work(:__timeout_trigger_waiting_nudge)) == %Retry{
               max_attempts: 2,
               backoff: {30, :seconds}
             }
    end
  end

  describe "Retry.delay_ms/2" do
    test "a fixed duration backoff is that duration in milliseconds, regardless of attempt" do
      retry = %Retry{backoff: {10, :seconds}}

      assert Retry.delay_ms(retry, 1) == 10_000
      assert Retry.delay_ms(retry, 2) == 10_000
      assert Retry.delay_ms(retry, 3) == 10_000
    end

    test "a fixed duration backoff in minutes converts to milliseconds" do
      retry = %Retry{backoff: {2, :minutes}}

      assert Retry.delay_ms(retry, 1) == 120_000
    end

    test ":exponential grows with the attempt number" do
      retry = %Retry{backoff: :exponential}

      assert Retry.delay_ms(retry, 1) == 16_000
      assert Retry.delay_ms(retry, 2) == 31_000
      assert Retry.delay_ms(retry, 3) == 96_000
    end
  end
end
