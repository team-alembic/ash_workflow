defmodule AshWorkflow.Verifiers.ValidateTimeoutPrecision do
  @moduledoc """
  Rejects timeouts whose deadline is shorter than the scheduler can poll for.

  Timeouts fire when an Oban cron scheduler next runs and finds the deadline
  has passed. Cron's finest granularity is one minute — `Oban.Cron` zeroes the
  seconds field and its scheduler only wakes on minute boundaries — so a
  deadline shorter than a minute cannot be honoured. `after: {30, :seconds}`
  compiles happily and then fires anywhere up to 60 seconds late, an error
  larger than the deadline itself.

  Rather than let the DSL make a promise the scheduler cannot keep, a
  sub-minute `after` is a compile error unless the timeout sets
  `self_scheduled?: true`, which asserts that something other than cron drives
  the trigger at the resolution the deadline needs.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @poll_floor_seconds 60

  @impl true
  def verify(dsl) do
    dsl
    |> Verifier.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.reject(& &1.terminal)
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, timeout}, :ok ->
      case validate(step, timeout) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate(_step, %{self_scheduled?: true}), do: :ok

  defp validate(step, timeout) do
    seconds = in_seconds(timeout.after)

    if seconds < @poll_floor_seconds do
      {:error,
       DslError.exception(
         path: [:workflow, :step, step.name, :timeout, timeout.name],
         message: message(step, timeout, seconds)
       )}
    else
      :ok
    end
  end

  defp message(step, timeout, _seconds) do
    {value, unit} = timeout.after

    """
    Timeout :#{timeout.name} on step :#{step.name} has after: {#{value}, :#{unit}}, \
    which is under a minute. Timeouts are polled by an Oban cron scheduler, and cron \
    cannot poll more often than once a minute, so this deadline would fire up to 60 \
    seconds late — later than the deadline itself.

    Either lengthen the deadline to at least one minute:

        timeout :#{timeout.name}, after: {1, :minutes}, ...

    or declare that you drive this trigger yourself, at whatever resolution the \
    deadline needs:

        timeout :#{timeout.name}, after: {#{value}, :#{unit}}, self_scheduled?: true, ...

    If you are using a custom field to carry the deadline, {1, :minutes} behaves \
    the same as a sub-minute duration — both mean "once that instant has passed", \
    and the polling interval decides how soon after.
    """
  end

  defp in_seconds({value, :seconds}), do: value
  defp in_seconds({value, :minutes}), do: value * 60
  defp in_seconds({value, :hours}), do: value * 3_600
  defp in_seconds({value, :days}), do: value * 86_400
end
