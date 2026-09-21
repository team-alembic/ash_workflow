defmodule AshWorkflow.Transformers.AddEveryBackfill do
  @moduledoc """
  Generates the migration that backfills each `every`'s last-fired column,
  for resources using `AshPostgres.DataLayer`.

  `AshWorkflow.Transformers.AddAttributes` adds a nilable column per `every`,
  which is `nil` on every row written before the column existed — as well as
  on any row that has genuinely never fired that `every`. A `nil` column is
  already treated as due (see `AshWorkflow.Entities.Every`), so an existing
  table only needs backfilling to avoid every row it holds firing at once the
  moment this ships: `up` sets the column to the same instant firing used to
  reset before this change, `state_entered_at`.

  Builds into `[:postgres, :custom_statements]` the same way
  `AshWorkflow.Transformers.AddIndexes` builds into `[:postgres,
  :custom_indexes]`: one `AshPostgres.Statement` per `every`, deduplicated by
  statement name rather than by the field-list comparison `AddIndexes` uses,
  since a statement has no field list to compare. `down` is `SELECT 1;` — a
  data backfill has no real inverse.

  The generated `UPDATE` names the table via the resource's `[:postgres]
  :schema` option when set. It does not qualify by a tenant's schema under
  schema-based multitenancy, since that schema is only known per connection at
  runtime, not at compile time when this transformer runs — a tenant resource
  needs its own backfill, run per tenant.

  Resources on other data layers are untouched.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Every
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    if postgres?(dsl) do
      {:ok, Enum.reduce(everys(dsl), dsl, &add_backfill(&2, &1))}
    else
      {:ok, dsl}
    end
  end

  defp postgres?(dsl), do: Transformer.get_persisted(dsl, :data_layer) == AshPostgres.DataLayer

  defp everys(dsl) do
    dsl
    |> Transformer.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.flat_map(fn step -> Enum.map(step.everys, &{step, &1}) end)
  end

  defp add_backfill(dsl, {step, every}) do
    field = Every.last_fired_field(step.name, every)
    name = statement_name(field)

    if statement_exists?(dsl, name) do
      dsl
    else
      statement =
        Transformer.build_entity!(
          AshPostgres.DataLayer,
          [:postgres, :custom_statements],
          :statement,
          name: name,
          up: "UPDATE #{qualified_table(dsl)} SET #{field} = state_entered_at;",
          down: "SELECT 1;"
        )

      Transformer.add_entity(dsl, [:postgres, :custom_statements], statement)
    end
  end

  defp qualified_table(dsl) do
    table = Transformer.get_option(dsl, [:postgres], :table)

    case Transformer.get_option(dsl, [:postgres], :schema) do
      nil -> table
      schema -> "#{schema}.#{table}"
    end
  end

  defp statement_name(field), do: :"backfill_#{field}"

  defp statement_exists?(dsl, name) do
    dsl
    |> Transformer.get_entities([:postgres, :custom_statements])
    |> Enum.any?(&(&1.name == name))
  end

  # Naming a backfill statement reads `Every.last_fired_field/2`, which is
  # pure naming and needs no attribute lookup, so this transformer does not
  # itself depend on `AddAttributes` having run. It runs after it anyway, so
  # the generated migration's structural `alter table` (adding the column)
  # and this data-only `UPDATE` land in the same deploy in the order a reader
  # would expect: column added, then backfilled.
  def after?(AshWorkflow.Transformers.AddAttributes), do: true
  def after?(_), do: false
end
