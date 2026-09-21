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
             validate_until(step, every)
           end),
         :ok <-
           Enum.reduce_while(entries, :ok, fn {step, every}, :ok ->
             validate_last_fired_field(dsl, step, every)
           end) do
      validate_no_shared_last_fired_field(dsl, entries)
    end
  end

  # An `every` fires immediately on entry, since its last-fired column starts
  # `nil` and a `nil` column is due regardless of `interval`. `until` does not
  # guard that first fire — it guards whether a *second* one is possible.
  # After the first fire, the column holds the entry instant, so the next fire
  # needs `entry + interval` to land before the bound, `entry + until`: that
  # is `until > interval` strictly. Equal durations leave zero room between
  # the two and the every fires once, on entry, and never again.
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
