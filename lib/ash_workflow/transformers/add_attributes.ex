defmodule AshWorkflow.Transformers.AddAttributes do
  @moduledoc """
  Adds the `state_entered_at` attribute if not already defined on the resource.

  This attribute tracks when the workflow entered its current state. It is used by
  timeout triggers to calculate whether a deadline has passed. The attribute is:

  - Type: `:utc_datetime_usec`
  - `allow_nil?: false` with a default of `DateTime.utc_now/0`
  - `public?: true` and `writable?: true`

  Does NOT add the `:state` attribute — that is handled by
  AshStateMachine's `AddState` transformer.

  If the user has already defined a `state_entered_at` attribute, this transformer
  is a no-op.

  ## `repeat_started_at`

  Also adds `repeat_started_at` (`:utc_datetime_usec`, nilable) when some
  timeout bounds its repeat with `until` and names no anchor of its own. Unlike
  `state_entered_at`, a repeating timeout's own firing never touches it. See
  `AshWorkflow.Entities.Repeat` for why the bound needs an anchor repeating
  cannot move.

  A workflow whose every bounded repeat names its own `field` never needs this
  attribute, and does not get it.

  Nilable because it is a new column on what may be an existing table: an
  in-flight record written before this attribute existed has no value for it
  until it next enters a step, and the bound treats that as "not yet reached"
  rather than raising.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Info, as: ResourceInfo
  alias AshWorkflow.Entities.Repeat
  alias AshWorkflow.Entities.Step
  alias AshWorkflow.Entities.Timeout
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
          writable?: true,
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
    default_field = Repeat.default_field()

    dsl
    |> DslTransformer.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.flat_map(& &1.timeouts)
    |> Enum.any?(&(Timeout.repeat_anchor_field(&1) == default_field))
  end

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
