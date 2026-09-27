defmodule AshWorkflow.Verifiers.ValidateTimeoutPrecision do
  @moduledoc """
  Rejects timeouts and `every` entities whose deadline is shorter than the
  selected scheduler can honour.

  The floor comes from the scheduler, through
  `AshWorkflow.Scheduler.precision_floor_ms/1`.
  `AshWorkflow.Scheduler.Oban` polls on a cron interval, and cron's finest
  granularity is one minute — `Oban.Cron` zeroes the seconds field and its
  scheduler only wakes on minute boundaries — so a deadline shorter than a
  minute cannot be honoured there. `fire_after: {30, :seconds}` compiles happily and
  then fires anywhere up to 60 seconds late, an error larger than the deadline
  itself. The same is true of an `every`'s `interval`.

  Rather than let the DSL make a promise the scheduler cannot keep, a deadline
  under the floor is a compile error unless the entity sets
  `self_scheduled?: true`, which asserts that something other than the
  scheduler drives the trigger at the resolution the deadline needs.

  `AshWorkflow.Scheduler.Precise` arms a timer per deadline, so its floor is a
  millisecond and a sub-minute deadline needs no flag.

  ## A `fire_at` timeout is skipped

  This check reads the duration an entity declares, `fire_after` on a timeout or
  `interval` on an `every`, and a `fire_at` timeout declares neither. It makes no duration promise:
  it says "once this instant has passed", and the polling interval decides how
  soon after. There is no promised precision to compare against the floor, so
  there is nothing to reject.

  Before `fire_at` existed, the same outcome was reached by writing
  `fire_after: {1, :seconds}` against a field holding the deadline instant. That
  sentinel handed this verifier a number that meant nothing, and the verifier
  checked it anyway. `fire_at` says the thing directly, and skipping it is
  correct by construction.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Info
  alias AshWorkflow.Scheduler
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    scheduler = Info.scheduler(dsl)
    floor_ms = Scheduler.precision_floor_ms(scheduler)

    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))
      |> Enum.reject(&Step.terminal?/1)

    timeouts = Enum.flat_map(steps, fn step -> Enum.map(step.timeouts, &{step, :timeout, &1}) end)
    everys = Enum.flat_map(steps, fn step -> Enum.map(step.everys, &{step, :every, &1}) end)

    (timeouts ++ everys)
    |> Enum.reduce_while(:ok, fn {step, kind, entity}, :ok ->
      case validate(step, kind, entity, scheduler, floor_ms) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate(_step, _kind, %{self_scheduled?: true}, _scheduler, _floor_ms), do: :ok

  defp validate(_step, :timeout, %{fire_at: fire_at}, _scheduler, _floor_ms)
       when not is_nil(fire_at),
       do: :ok

  # A wall-clock `every` names an occurrence rather than a duration. Two
  # occurrences of the same daily time are a day apart, which clears every
  # scheduler's floor, so there is nothing here to be too short.
  defp validate(_step, :every, %{at: at}, _scheduler, _floor_ms) when not is_nil(at), do: :ok

  defp validate(step, kind, entity, {module, _opts}, floor_ms) do
    duration = duration(kind, entity)

    if AshWorkflow.Duration.to_milliseconds(duration) < floor_ms do
      {:error,
       DslError.exception(
         path: [:workflow, :step, step.name, kind, entity.name],
         message: message(step, kind, entity, duration, module, floor_ms)
       )}
    else
      :ok
    end
  end

  defp duration(:timeout, timeout), do: timeout.fire_after
  defp duration(:every, every), do: every.interval

  defp message(step, :timeout, timeout, duration, module, floor_ms) do
    {value, unit} = duration

    """
    Timeout :#{timeout.name} on step :#{step.name} has fire_after: {#{value}, :#{unit}}, \
    which is shorter than #{inspect(module)} can honour. That scheduler checks no more \
    often than every #{humanize(floor_ms)}, so this deadline would fire up to \
    #{humanize(floor_ms)} late, which is later than the deadline itself.

    Either lengthen the deadline past that floor:

        timeout :#{timeout.name}, fire_after: {#{floor_value(floor_ms)}}, ...

    or select a scheduler that fires precisely:

        workflow do
          scheduler AshWorkflow.Scheduler.Precise
        end

    or declare that you drive this trigger yourself, at whatever resolution the \
    deadline needs:

        timeout :#{timeout.name}, fire_after: {#{value}, :#{unit}}, self_scheduled?: true, ...

    If the field already holds the deadline instant rather than an anchor to \
    measure from, name it with fire_at instead. A fire_at timeout promises no \
    duration, so this check does not apply to it:

        timeout :#{timeout.name}, fire_at: :your_deadline_field, ...
    """
  end

  defp message(step, :every, every, duration, module, floor_ms) do
    {value, unit} = duration

    """
    every :#{every.name} on step :#{step.name} has interval: {#{value}, :#{unit}}, \
    which is shorter than #{inspect(module)} can honour. That scheduler checks no more \
    often than every #{humanize(floor_ms)}, so this action would fire up to \
    #{humanize(floor_ms)} late relative to the interval.

    Either lengthen the interval past that floor:

        every :#{every.name}, interval: {#{floor_value(floor_ms)}}, ...

    or select a scheduler that fires precisely:

        workflow do
          scheduler AshWorkflow.Scheduler.Precise
        end

    or declare that you drive this trigger yourself, at whatever resolution the \
    interval needs:

        every :#{every.name}, interval: {#{value}, :#{unit}}, self_scheduled?: true, ...
    """
  end

  defp humanize(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp humanize(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp humanize(ms), do: "#{ms}ms"

  defp floor_value(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}, :minutes"
  defp floor_value(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}, :seconds"
  defp floor_value(_ms), do: "1, :seconds"
end
