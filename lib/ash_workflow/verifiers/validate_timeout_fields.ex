defmodule AshWorkflow.Verifiers.ValidateTimeoutFields do
  @moduledoc """
  Verifies that timeout `field` options are valid.

  Checks:
  - A timeout's `field`, and a `repeat` block's `field`, reference existing datetime
    attributes or expression calculations on the resource
  - A repeating timeout does not combine `repeat` with a custom `field`, since the
    repeat mechanism resets `state_entered_at` rather than that field
  - A `repeat` block's `until` is strictly longer than `fire_after`
  - A `repeat` block's anchor `field` is not one the repeat itself resets
  - `until` is not declared on a `repeat false`

  Runs after all transformers have added attributes and calculations to the resource.
  Skips existence validation for `:state_entered_at` and `:repeat_started_at`, which
  the extension adds itself.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Repeat
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    steps
    |> Enum.reject(&Step.terminal?/1)
    |> Enum.flat_map(fn step -> Enum.map(step.timeouts, &{step, &1}) end)
    |> Enum.reduce_while(:ok, fn {step, timeout}, :ok ->
      with {:cont, :ok} <- validate_no_repeat_with_custom_field(step, timeout),
           {:cont, :ok} <- validate_until_needs_repeat(step, timeout),
           {:cont, :ok} <- validate_repeat_until(step, timeout),
           {:cont, :ok} <- validate_repeat_anchor(dsl, step, timeout) do
        validate_field_exists(dsl, step, timeout)
      end
    end)
  end

  defp validate_until_needs_repeat(
         step,
         %{repeat: %Repeat{enabled?: false, until: until}} = timeout
       )
       when not is_nil(until) do
    {:halt,
     {:error,
      DslError.exception(
        path: [:workflow, :step, step.name],
        message:
          "Timeout :#{timeout.name} on step :#{step.name} declares `repeat false` with `until #{inspect(until)}`. " <>
            "A bound on repeating means nothing when the timeout does not repeat. Drop the `until`, or turn the repeat on."
      )}}
  end

  defp validate_until_needs_repeat(_step, _timeout), do: {:cont, :ok}

  # A timeout fires when its field is at or before `now - fire_after`, and the
  # bound requires its anchor to be after `now - until`. Both anchors start out
  # at the same instant, so the first fire needs `now - until < now -
  # fire_after`, which is `until > fire_after` strictly. Equal durations leave
  # zero room between the two conditions and the timeout never fires at all.
  defp validate_repeat_until(step, timeout) do
    case Timeout.repeat_until(timeout) do
      nil ->
        {:cont, :ok}

      until ->
        fire_after_seconds = AshWorkflow.Duration.to_seconds(timeout.fire_after)
        until_seconds = AshWorkflow.Duration.to_seconds(until)

        if until_seconds <= fire_after_seconds do
          {:halt,
           {:error,
            DslError.exception(
              path: [:workflow, :step, step.name],
              message:
                "Timeout :#{timeout.name} on step :#{step.name} has until: #{inspect(until)} in its repeat, " <>
                  "which is not longer than fire_after: #{inspect(timeout.fire_after)}. The timeout would never fire " <>
                  "even once before the bound is reached. `until` must be strictly greater than `fire_after`."
            )}}
        else
          {:cont, :ok}
        end
    end
  end

  # The bound exists to be reached, so its anchor must be a timestamp the
  # repeat does not itself move. `state_entered_at` is exactly the one it
  # resets on every firing, which is the whole reason `repeat_started_at`
  # exists.
  defp validate_repeat_anchor(dsl, step, timeout) do
    case Timeout.repeat_anchor_field(timeout) do
      nil ->
        {:cont, :ok}

      :state_entered_at ->
        {:halt,
         {:error,
          DslError.exception(
            path: [:workflow, :step, step.name],
            message:
              "Timeout :#{timeout.name} on step :#{step.name} anchors its repeat bound on :state_entered_at, " <>
                "which the repeat resets on every firing, so the bound would never be reached. Leave `field` " <>
                "unset to use :#{Repeat.default_field()}, or name a timestamp the repeat does not move."
          )}}

      field ->
        validate_datetime_field(dsl, step, timeout, field, "anchors its repeat bound on")
    end
  end

  defp validate_no_repeat_with_custom_field(step, timeout) do
    if Timeout.repeats?(timeout) and timeout.field != :state_entered_at do
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} repeats with field: :#{timeout.field}. " <>
              "Repeating timeouts are not supported with custom fields because the repeat mechanism " <>
              "resets state_entered_at, not the custom field. Use the default field, or do not repeat."
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
    validate_datetime_field(dsl, step, timeout, timeout.field, "references field")
  end

  # Shared by the timeout's own `field` and by a repeat's anchor `field`, since
  # both are referenced from the trigger's filter and carry the same
  # requirements. `description` is what the error says the timeout did with it.
  defp validate_datetime_field(_dsl, _step, _timeout, field, _description)
       when field in [:state_entered_at, :repeat_started_at],
       do: {:cont, :ok}

  defp validate_datetime_field(dsl, step, timeout, field, description) do
    attribute = ResourceInfo.attribute(dsl, field)
    calculation = ResourceInfo.calculation(dsl, field)

    cond do
      attribute != nil ->
        validate_field_type(attribute.type, step, timeout, field)

      calculation != nil ->
        with {:cont, :ok} <- validate_calculation_is_expression(calculation, step, timeout, field) do
          validate_field_type(calculation.type, step, timeout, field)
        end

      true ->
        {:halt,
         {:error,
          DslError.exception(
            path: [:workflow, :step, step.name],
            message:
              "Timeout :#{timeout.name} on step :#{step.name} #{description} :#{field}, " <>
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
         timeout,
         field
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
            "Timeout :#{timeout.name} on step :#{step.name} references calculation :#{field}, " <>
              "which is a module calculation and so cannot be evaluated by the data layer. " <>
              "Timeout fields are used in the trigger's filter, so a calculation must be " <>
              "expression-based (`calculate :#{field}, :utc_datetime_usec, expr(...)`) " <>
              "or you must use a plain attribute."
        )}}
    end
  end

  defp validate_calculation_is_expression(_calculation, _step, _timeout, _field), do: {:cont, :ok}

  defp validate_field_type(type, step, timeout, field) do
    storage_type = Ash.Type.storage_type(type)

    if storage_type in @datetime_storage_types do
      {:cont, :ok}
    else
      {:halt,
       {:error,
        DslError.exception(
          path: [:workflow, :step, step.name],
          message:
            "Timeout :#{timeout.name} on step :#{step.name} references field :#{field} " <>
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
            "Timeout :#{timeout.name} on step :#{step.name} references field :#{field} " <>
              "which has type #{inspect(type)} that could not be resolved. " <>
              "Timeout fields must be a datetime type."
        )}}
  end
end
