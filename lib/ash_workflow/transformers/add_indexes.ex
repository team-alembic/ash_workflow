defmodule AshWorkflow.Transformers.AddIndexes do
  @moduledoc """
  Adds the composite indexes that the generated Oban triggers need, for
  resources using `AshPostgres.DataLayer`.

  Every generated trigger filters on `state`, and every timeout trigger also
  filters on its `field`. `ago/2` compiles to a bind parameter rather than a
  per-row function call, so a timeout's `where` reaches Postgres as
  `state = $1 AND state_entered_at <= $2` — an ordinary composite range scan.
  Without an index that is a sequential scan on every poll, for every timeout.

  Indexes are named `ash_workflow_<table>_<fields>_index` so they are
  recognisable in migrations as belonging to this extension, and are only added
  when no existing `custom_indexes` entry already covers the same fields —
  a user-declared index always wins.

  Resources on other data layers are untouched; see
  `AshWorkflow.Info.recommended_indexes/1` for the same information as data.

  Opt out per resource with `workflow do generate_indexes? false end`.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def transform(dsl) do
    if generate?(dsl) do
      {:ok, Enum.reduce(AshWorkflow.Info.recommended_indexes(dsl), dsl, &add_index(&2, &1))}
    else
      {:ok, dsl}
    end
  end

  defp generate?(dsl) do
    Transformer.get_option(dsl, [:workflow], :generate_indexes?, true) and
      Transformer.get_persisted(dsl, :data_layer) == AshPostgres.DataLayer
  end

  defp add_index(dsl, fields) do
    if index_exists?(dsl, fields) do
      dsl
    else
      index =
        Transformer.build_entity!(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: fields,
          name: index_name(dsl, fields),
          concurrently: true
        )

      Transformer.add_entity(dsl, [:postgres, :custom_indexes], index)
    end
  end

  defp index_exists?(dsl, fields) do
    wanted = normalize_fields(fields)

    dsl
    |> Transformer.get_entities([:postgres, :custom_indexes])
    |> Enum.any?(fn index -> normalize_fields(index.fields) == wanted end)
  end

  # Custom index fields may be atoms, strings, or {field, order} tuples.
  defp normalize_fields(fields) do
    Enum.map(fields, fn
      {field, _order} -> to_string(field)
      field -> to_string(field)
    end)
  end

  # Timeout fields are checked against the resource's attributes to tell columns
  # from calculations, so `state_entered_at` must already have been added.
  def after?(AshWorkflow.Transformers.AddAttributes), do: true
  def after?(_), do: false

  defp index_name(dsl, fields) do
    table = Transformer.get_option(dsl, [:postgres], :table) || "workflow"

    "ash_workflow_#{table}_#{Enum.join(fields, "_")}_index"
  end
end
