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

  ## `repeat_started_at`

  Also adds `repeat_started_at` (`:utc_datetime_usec`, nilable) when some
  `every` bounds its firing with `until`. Unlike `state_entered_at`, an
  `every`'s own firing never touches it. See `AshWorkflow.Entities.Every` for
  why the bound needs an anchor firing cannot move.

  Nilable because it is a new column on what may be an existing table: an
  in-flight record written before this attribute existed has no value for it
  until it next enters a step, and the bound treats that as "not yet reached"
  rather than raising.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Transformer, as: DslTransformer

  def transform(dsl) do
    with {:ok, dsl} <- add_state_entered_at(dsl) do
      add_repeat_started_at(dsl)
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

  defp add_repeat_started_at(dsl) do
    if needs_repeat_started_at?(dsl) and ResourceInfo.attribute(dsl, :repeat_started_at) == nil do
      Builder.add_attribute(dsl, :repeat_started_at, :utc_datetime_usec,
        allow_nil?: true,
        writable?: true,
        public?: true
      )
    else
      {:ok, dsl}
    end
  end

  defp needs_repeat_started_at?(dsl) do
    dsl
    |> DslTransformer.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.flat_map(& &1.everys)
    |> Enum.any?(&(&1.until != nil))
  end

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
