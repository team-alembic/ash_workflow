defmodule AshWorkflow.Verifiers.ValidateTimeoutFields do
  @moduledoc """
  Verifies that timeout `field` options are valid.

  Checks:
  - Custom fields reference existing attributes or calculations on the resource
  - `repeat: true` is not combined with a custom field (see `Entities.Timeout` for rationale)

  Runs after all transformers have added attributes and calculations to the resource.
  Skips field existence validation for the default `:state_entered_at` since it is always present.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    steps
    |> Enum.reject(& &1.terminal)
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, timeout}, :ok ->
      with {:cont, :ok} <- validate_no_repeat_with_custom_field(step, timeout) do
        validate_field_exists(dsl, step, timeout)
      end
    end)
  end

  defp validate_no_repeat_with_custom_field(step, timeout) do
    if timeout.repeat and timeout.field != :state_entered_at do
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} has repeat: true with field: :#{timeout.field}. " <>
              "Repeating timeouts are not supported with custom fields because the repeat mechanism " <>
              "resets state_entered_at, not the custom field. Use the default field or remove repeat: true."
        )}}
    else
      {:cont, :ok}
    end
  end

  defp validate_field_exists(_dsl, _step, %{field: :state_entered_at}), do: {:cont, :ok}

  @datetime_storage_types [
    :utc_datetime,
    :utc_datetime_usec,
    :naive_datetime,
    :naive_datetime_usec
  ]

  defp validate_field_exists(dsl, step, timeout) do
    attribute = ResourceInfo.attribute(dsl, timeout.field)
    calculation = ResourceInfo.calculation(dsl, timeout.field)

    cond do
      attribute != nil ->
        validate_field_type(attribute.type, step, timeout)

      calculation != nil ->
        with {:cont, :ok} <- validate_calculation_is_expression(calculation, step, timeout) do
          validate_field_type(calculation.type, step, timeout)
        end

      true ->
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

  # Timeout fields are referenced from the trigger's `where` clause, which the
  # data layer evaluates as SQL. Only expression calculations inline into a
  # filter; a module calculation is computed in Elixir after the read and would
  # raise when the scheduler builds its query.
  defp validate_calculation_is_expression(
         %{calculation: {module, _opts}} = _calculation,
         step,
         timeout
       ) do
    Code.ensure_compiled(module)

    if function_exported?(module, :expression, 2) do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} references calculation :#{timeout.field}, " <>
              "which is a module calculation and so cannot be evaluated by the data layer. " <>
              "Timeout fields are used in the trigger's filter, so a calculation must be " <>
              "expression-based (`calculate :#{timeout.field}, :utc_datetime_usec, expr(...)`) " <>
              "or you must use a plain attribute."
        )}}
    end
  end

  defp validate_calculation_is_expression(_calculation, _step, _timeout), do: {:cont, :ok}

  defp validate_field_type(type, step, timeout) do
    storage_type = Ash.Type.storage_type(type)

    if storage_type in @datetime_storage_types do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} references field :#{timeout.field} " <>
              "which has type #{inspect(type)}, but timeout fields must be a datetime type."
        )}}
    end
  rescue
    _ ->
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} references field :#{timeout.field} " <>
              "which has type #{inspect(type)} that could not be resolved. " <>
              "Timeout fields must be a datetime type."
        )}}
  end
end
