defmodule AshWorkflow.Verifiers.ValidateEvery do
  @moduledoc """
  Verifies that an `every`'s `until` bound is coherent, and that its
  `last_fired_field` — explicit or generated — is a column `every` can
  safely own.

  Separate from `AshWorkflow.Verifiers.ValidateTimeoutFields`, which is about a
  timeout's `field` — a concept `every` does not have. `every` measures its
  `interval` against its own last-fired column, and its `until` bound always
  measures against `state_entered_at`.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @datetime_storage_types [
    :utc_datetime,
    :utc_datetime_usec,
    :naive_datetime,
    :naive_datetime_usec
  ]

  @impl true
  def verify(dsl) do
    entries =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))
      |> Enum.flat_map(fn step -> Enum.map(step.everys, &{step, &1}) end)

    with :ok <-
           Enum.reduce_while(entries, :ok, fn {step, every}, :ok ->
             validate_schedule(dsl, step, every)
           end),
         :ok <-
           Enum.reduce_while(entries, :ok, fn {step, every}, :ok ->
             validate_until(step, every)
           end),
         :ok <-
           Enum.reduce_while(entries, :ok, fn {step, every}, :ok ->
             validate_last_fired_field(dsl, step, every)
           end) do
      validate_no_shared_last_fired_field(dsl, entries)
    end
  end

  # `interval` measures from the last fire and `at` names a wall-clock time in
  # a zone. A record cannot be due on both rules at once, and picking one for
  # the developer would mean the DSL silently ignoring what they wrote.
  defp validate_schedule(dsl, step, every) do
    case {schedule_conflict(every), every.at} do
      {nil, nil} -> {:cont, :ok}
      {nil, _at} -> validate_time_zone(dsl, step, every)
      {message, _at} -> schedule_error(step, every, message)
    end
  end

  defp schedule_conflict(%{at: nil, interval: nil}),
    do: "declares neither interval nor at. One of the two is required."

  # An `interval` alongside `at` is a stride: how many local days apart two
  # fires must be. Only `:days` can say that. A 36-hour stride never lands on
  # the same wall-clock time twice running, so it would silently mean
  # something other than what it says.
  defp schedule_conflict(%{at: at, interval: {value, unit}})
       when not is_nil(at) and unit != :days do
    "declares at: #{inspect(at)} alongside interval: #{inspect({value, unit})}. An interval " <>
      "beside an at counts local days between fires, so it must be given in :days. A stride " <>
      "shorter than a day cannot land on the same wall-clock time twice running."
  end

  defp schedule_conflict(%{at: nil, on: on}) when not is_nil(on),
    do: "declares on: #{inspect(on)} without an at to fire."

  defp schedule_conflict(%{at: nil, time_zone: time_zone}) when not is_nil(time_zone) do
    "declares time_zone: #{inspect(time_zone)} without an at to place in that zone. An interval " <>
      "is a duration, and a duration is the same length in every zone."
  end

  defp schedule_conflict(%{at: at, time_zone: nil}) when not is_nil(at) do
    "declares at: #{inspect(at)} without a time_zone. A wall-clock time is not an instant until " <>
      ~s|a zone places it, so name the attribute holding the record's zone, or a literal such | <>
      ~s|as "Australia/Sydney".|
  end

  defp schedule_conflict(_every), do: nil

  defp validate_time_zone(_dsl, step, %{time_zone: zone} = every) when is_binary(zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _shifted} ->
        {:cont, :ok}

      {:error, reason} ->
        schedule_error(
          step,
          every,
          "declares time_zone: #{inspect(zone)}, which the configured time zone database " <>
            "rejected with #{inspect(reason)}. Set :time_zone_database in config, and check " <>
            "the zone name against the IANA database."
        )
    end
  end

  # A zone can come from a calculation as well as an attribute, which is how a
  # record reads its zone off a related one:
  #
  #     calculate :candidate_time_zone, :string, expr(candidate.time_zone)
  #
  # Checked the same way `AshWorkflow.Verifiers.ValidateTimeoutFields` checks a
  # timeout's `field`, and for the same reason: the trigger's `where` clause is
  # evaluated by the data layer, so only an expression calculation can inline
  # into it.
  defp validate_time_zone(dsl, step, every) do
    field = every.time_zone
    attribute = ResourceInfo.attribute(dsl, field)
    calculation = ResourceInfo.calculation(dsl, field)

    cond do
      attribute != nil ->
        validate_time_zone_type(attribute.type, step, every)

      calculation != nil ->
        with {:cont, :ok} <- validate_time_zone_is_expression(calculation, step, every) do
          validate_time_zone_type(calculation.type, step, every)
        end

      true ->
        schedule_error(
          step,
          every,
          "declares time_zone: #{inspect(field)}, but no attribute or calculation with that " <>
            "name exists on the resource. Name an existing one, or give a literal zone as a " <>
            "string."
        )
    end
  rescue
    _ -> {:cont, :ok}
  end

  defp validate_time_zone_is_expression(%{calculation: {module, _opts}}, step, every) do
    Code.ensure_compiled(module)

    if function_exported?(module, :expression, 2) do
      {:cont, :ok}
    else
      schedule_error(
        step,
        every,
        "declares time_zone: #{inspect(every.time_zone)}, which is a module calculation and so " <>
          "cannot be evaluated by the data layer. The zone is read from the trigger's filter, " <>
          "so a calculation must be expression-based " <>
          "(`calculate :#{every.time_zone}, :string, expr(...)`), or you must name a plain " <>
          "attribute."
      )
    end
  end

  defp validate_time_zone_is_expression(_calculation, _step, _every), do: {:cont, :ok}

  defp validate_time_zone_type(type, step, every) do
    if Ash.Type.storage_type(type) in [:string, :text, :ci_string] do
      {:cont, :ok}
    else
      schedule_error(
        step,
        every,
        "declares time_zone: #{inspect(every.time_zone)}, which has type #{inspect(type)}. " <>
          "A zone is an IANA name, so it must be a string."
      )
    end
  end

  defp schedule_error(step, every, message) do
    {:halt,
     {:error,
      DslError.exception(
        path: [:workflow, :step, step.name, :every, every.name],
        message: "every :#{every.name} on step :#{step.name} #{message}"
      )}}
  end

  # An `every`'s first fire lands one whole `interval` after entry, since its
  # last-fired column starts `nil` and the interval is then measured from
  # `state_entered_at`. The bound is `entry + until`, so that first fire
  # happens only if `interval < until`: that is `until > interval` strictly.
  # Equal durations leave no room and the every never fires at all.
  defp validate_until(_step, %{until: nil}), do: {:cont, :ok}

  # An `at` every has no interval to compare the bound against. Its first fire
  # is the first occurrence after entry, which may be nearly a week away for a
  # single-day `on`, so there is no duration this verifier could check.
  defp validate_until(_step, %{interval: nil}), do: {:cont, :ok}

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
              "which is not longer than interval: #{inspect(interval)}. It would fire once, " <>
              "on entry, and never a second time before the bound is reached. `until` must be " <>
              "strictly greater than `interval`."
        )}}
    else
      {:cont, :ok}
    end
  end

  # `AshWorkflow.Transformers.AddAttributes` always creates the column, unless
  # a same-named attribute already exists on the resource — the same pattern
  # `state_entered_at` itself follows. Naming `last_fired_field` after an
  # existing attribute is a legitimate way to reuse a column, but only if that
  # column is a datetime `every` can write `now()` into. Naming it
  # `:state_entered_at` specifically reintroduces the exact bug this design
  # avoids: `RecordEvent` would write the every's fire straight onto the
  # anchor every other deadline on the step measures from.
  defp validate_last_fired_field(dsl, step, every) do
    field = Every.last_fired_field(step.name, every)

    cond do
      field == :state_entered_at ->
        {:halt,
         {:error,
          DslError.exception(
            path: [:workflow, :step, step.name],
            message:
              "every :#{every.name} on step :#{step.name} has last_fired_field: :state_entered_at. " <>
                "AshWorkflow.Changes.RecordEvent would then write the every's own fire onto the " <>
                "anchor every other deadline on the step measures from, reintroducing the " <>
                "starvation this design exists to avoid. Choose a different field."
          )}}

      field == AshWorkflow.Info.state_attribute(dsl) ->
        {:halt,
         {:error,
          DslError.exception(
            path: [:workflow, :step, step.name],
            message:
              "every :#{every.name} on step :#{step.name} has last_fired_field: :#{field}, " <>
                "which is the workflow's own state attribute."
          )}}

      true ->
        validate_last_fired_field_type(dsl, step, every, field)
    end
  end

  defp validate_last_fired_field_type(dsl, step, every, field) do
    case ResourceInfo.attribute(dsl, field) do
      nil ->
        {:cont, :ok}

      attribute ->
        if Ash.Type.storage_type(attribute.type) in @datetime_storage_types do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            DslError.exception(
              path: [:workflow, :step, step.name],
              message:
                "every :#{every.name} on step :#{step.name} has last_fired_field: :#{field}, " <>
                  "which references an existing attribute of type #{inspect(attribute.type)}. " <>
                  "An every's last-fired column must be a datetime type."
            )}}
        end
    end
  rescue
    _ -> {:cont, :ok}
  end

  # Two everys resolving to the same column, whether both explicit or one
  # colliding with another's generated default, would have one fire silently
  # count as the other's — the same shared-anchor starvation this design
  # otherwise avoids, just moved to a smaller blast radius.
  defp validate_no_shared_last_fired_field(_dsl, entries) do
    entries
    |> effective_fields()
    |> Enum.group_by(fn {field, _step, _every} -> field end)
    |> Enum.reduce_while(:ok, fn {field, group}, :ok -> validate_field_group(field, group) end)
  end

  defp validate_field_group(_field, [_one]), do: {:cont, :ok}

  defp validate_field_group(field, many) do
    names =
      Enum.map_join(many, ", ", fn {_field, step, every} -> "#{step.name}.#{every.name}" end)

    {:halt,
     {:error,
      DslError.exception(
        path: [:workflow],
        message:
          "last_fired_field :#{field} is shared by more than one every: #{names}. " <>
            "Each every needs its own column, or one's fire silently counts as the other's."
      )}}
  end

  defp effective_fields(entries) do
    Enum.map(entries, fn {step, every} ->
      {Every.last_fired_field(step.name, every), step, every}
    end)
  end
end
