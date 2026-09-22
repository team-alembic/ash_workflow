defmodule AshWorkflow.Verifiers.ValidateEvery do
  @moduledoc """
  Verifies that an `every`'s `until` bound is coherent.

  Checks that `until` is strictly longer than `interval`.

  Separate from `AshWorkflow.Verifiers.ValidateTimeoutFields`, which is about a
  timeout's `field` — a concept `every` does not have. `every` always measures
  against `state_entered_at` and its bound always measures against
  `AshWorkflow.Entities.Every.until_anchor/0`, so there is no field to
  validate, only the one duration comparison below.
  """
  use Spark.Dsl.Verifier

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    dsl
    |> Verifier.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.flat_map(fn step -> Enum.map(step.everys, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, every}, :ok ->
      validate_until(step, every)
    end)
  end

  # An `every` fires when its anchor is at or before `now - interval`, and the
  # bound requires `repeat_started_at` to be after `now - until`. Both anchors
  # start out at the same instant, so the first fire needs `now - until < now -
  # interval`, which is `until > interval` strictly. Equal durations leave zero
  # room between the two conditions and the every never fires at all.
  defp validate_until(_step, %{until: nil}), do: {:cont, :ok}

  defp validate_until(step, %{until: until, interval: interval} = every) do
    interval_seconds = AshWorkflow.Duration.to_seconds(interval)
    until_seconds = AshWorkflow.Duration.to_seconds(until)

    if until_seconds <= interval_seconds do
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "every :#{every.name} on step :#{step.name} has until: #{inspect(until)}, " <>
              "which is not longer than interval: #{inspect(interval)}. It would never fire " <>
              "even once before the bound is reached. `until` must be strictly greater than `interval`."
        )}}
    else
      {:cont, :ok}
    end
  end
end
