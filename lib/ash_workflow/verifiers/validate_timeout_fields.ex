defmodule AshWorkflow.Verifiers.ValidateTimeoutFields do
  @moduledoc """
  Verifies that timeout `field` options reference existing attributes or calculations.

  Runs after all transformers have added attributes and calculations to the resource.
  Skips validation for the default `:state_entered_at` field since it is always present.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    steps = Verifier.get_entities(dsl, [:workflow])

    steps
    |> Enum.reject(& &1.terminal)
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, timeout}, :ok ->
      if timeout.field == :state_entered_at do
        {:cont, :ok}
      else
        validate_field_exists(dsl, step, timeout)
      end
    end)
  end

  defp validate_field_exists(dsl, step, timeout) do
    has_attribute? = ResourceInfo.attribute(dsl, timeout.field) != nil
    has_calculation? = ResourceInfo.calculation(dsl, timeout.field) != nil

    if has_attribute? or has_calculation? do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} references field :#{timeout.field}, " <>
              "but no attribute or calculation with that name exists on the resource."
        )}}
    end
  end
end
