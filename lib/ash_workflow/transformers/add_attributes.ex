defmodule AshWorkflow.Transformers.AddAttributes do
  @moduledoc """
  Adds the `state_entered_at` attribute if not already defined on the resource.

  This attribute tracks when the workflow entered its current state. It is used by
  timeout triggers to calculate whether a deadline has passed. The attribute is:

  - Type: `:utc_datetime_usec`
  - `allow_nil?: false` with a default of `DateTime.utc_now/0`
  - `public?: true` and `writable?: false`

  `writable?: false` keeps the attribute out of every action's `accept` list and
  rejects it as an argument, so nothing outside AshWorkflow can move a record's
  anchor. `AshWorkflow.Changes.RecordEvent` writes it with
  `Ash.Changeset.force_change_attribute/3`, which bypasses `writable?`, and the
  atomic path writes it through the `%{state_entered_at: expr(now())}` map
  `atomic/3` returns. Both are unaffected.

  Every deadline on a step measures from this attribute, so a write from
  outside moves every one of them at once. A caller that genuinely needs to set
  it (backfilling imported records, say) can still reach it with
  `force_change_attribute/3` or the data layer directly.

  Does NOT add the `:state` attribute — that is handled by
  AshStateMachine's `AddState` transformer.

  If the user has already defined a `state_entered_at` attribute, this transformer
  is a no-op.

  ## `every` last-fired columns

  Also adds one nilable `:utc_datetime_usec` attribute per `every`, named by
  `AshWorkflow.Entities.Every.last_fired_field/2`. `AshWorkflow.Changes.RecordEvent`
  writes it on that `every`'s firing, and `AshWorkflow.Transformers.AddScheduler`
  measures the `every`'s `interval` against it instead of `state_entered_at`. See
  `AshWorkflow.Entities.Every` for why firing no longer touches
  `state_entered_at`.

  Nilable because it is a new column on what may be an existing table: an
  in-flight record written before this attribute existed has no value for it
  until it next fires. `AshWorkflow.Transformers.AddEveryBackfill` generates a
  migration backfilling it from `state_entered_at` for `AshPostgres.DataLayer`
  resources; elsewhere, and until that backfill runs, a `nil` column is treated
  as due.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Transformer, as: DslTransformer

  def transform(dsl) do
    with {:ok, dsl} <- add_state_entered_at(dsl) do
      add_every_last_fired_fields(dsl)
    end
  end

  defp add_state_entered_at(dsl) do
    case ResourceInfo.attribute(dsl, :state_entered_at) do
      nil ->
        Builder.add_attribute(dsl, :state_entered_at, :utc_datetime_usec,
          allow_nil?: false,
          default: &DateTime.utc_now/0,
          writable?: false,
          public?: true
        )

      _exists ->
        {:ok, dsl}
    end
  end

  defp add_every_last_fired_fields(dsl) do
    dsl
    |> every_fields()
    |> Enum.reduce({:ok, dsl}, fn field, {:ok, dsl} -> add_every_last_fired_field(dsl, field) end)
  end

  defp add_every_last_fired_field(dsl, field) do
    case ResourceInfo.attribute(dsl, field) do
      nil ->
        Builder.add_attribute(dsl, field, :utc_datetime_usec,
          allow_nil?: true,
          writable?: false,
          public?: true
        )

      _exists ->
        {:ok, dsl}
    end
  end

  defp every_fields(dsl) do
    dsl
    |> DslTransformer.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.flat_map(fn step -> Enum.map(step.everys, &Every.last_fired_field(step.name, &1)) end)
  end

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
