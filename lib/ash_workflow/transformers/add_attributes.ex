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
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Info, as: ResourceInfo

  def transform(dsl) do
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

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
