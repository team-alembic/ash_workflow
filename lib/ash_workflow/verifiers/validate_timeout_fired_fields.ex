defmodule AshWorkflow.Verifiers.ValidateTimeoutFiredFields do
  @moduledoc """
  Verifies that each action timeout's `<step>_<timeout>_fired_at` column is one
  the timeout can safely own.

  `AshWorkflow.Transformers.AddAttributes` adds the column unless an attribute
  with that name already exists, the same as an `every`'s last-fired column.
  This verifier rejects two cases:

    * an existing attribute with that name whose type is not a datetime, since
      `AshWorkflow.Changes.RecordEvent` writes the firing instant into it;
    * two action timeouts, or an action timeout and an `every`, that resolve to
      the same column. Step `:a_b` with timeout `:c` and step `:a` with timeout
      `:b_c` both generate `:a_b_c_fired_at`, and one's firing would count as
      the other's.

  `AshWorkflow.Verifiers.ValidateEvery` checks two `every`s sharing a column.
  """
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
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
    steps =
      dsl
      |> Verifier.get_entities([:workflow])
      |> Enum.filter(&match?(%Step{}, &1))

    timeout_fields =
      Enum.flat_map(steps, fn step ->
        step.timeouts
        |> Enum.map(
          &{Timeout.fired_field(step.name, &1), "timeout :#{&1.name} on step :#{step.name}"}
        )
        |> Enum.reject(fn {field, _owner} -> is_nil(field) end)
      end)

    every_fields =
      Enum.flat_map(steps, fn step ->
        Enum.map(step.everys, fn every ->
          {Every.last_fired_field(step.name, every), "every :#{every.name} on step :#{step.name}"}
        end)
      end)

    with :ok <- validate_types(dsl, timeout_fields) do
      validate_unique(timeout_fields, every_fields)
    end
  end

  defp validate_types(dsl, timeout_fields) do
    Enum.reduce_while(timeout_fields, :ok, fn {field, owner}, :ok ->
      case validate_type(ResourceInfo.attribute(dsl, field), field, owner) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_type(nil, _field, _owner), do: :ok

  defp validate_type(attribute, field, owner) do
    if datetime?(attribute.type) do
      :ok
    else
      error(
        "The #{owner} records its firing in :#{field}, which is an existing " <>
          "attribute of type #{inspect(attribute.type)}. An action timeout's fired " <>
          "column must be a datetime type. Rename the timeout or the attribute."
      )
    end
  end

  defp datetime?(type) do
    Ash.Type.storage_type(type) in @datetime_storage_types
  rescue
    _ -> false
  end

  defp validate_unique(timeout_fields, every_fields) do
    (timeout_fields ++ every_fields)
    |> Enum.group_by(fn {field, _owner} -> field end, fn {_field, owner} -> owner end)
    |> Enum.filter(fn {field, owners} ->
      length(owners) > 1 and Enum.any?(timeout_fields, &(elem(&1, 0) == field))
    end)
    |> case do
      [] ->
        :ok

      [{field, owners} | _rest] ->
        error(
          "#{Enum.join(owners, ", ")} all record their firing in :#{field}. " <>
            "Each needs its own column, or one's firing counts as the other's. " <>
            fix_hint(owners)
        )
    end
  end

  defp fix_hint(owners) do
    if Enum.any?(owners, &String.starts_with?(&1, "every ")),
      do: "Rename the timeout, or give the every a different last_fired_field.",
      else: "Rename one of the timeouts."
  end

  defp error(message) do
    {:error, DslError.exception(path: [:workflow], message: message)}
  end
end
