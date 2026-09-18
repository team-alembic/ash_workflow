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

  Also adds `repeat_started_at` (`:utc_datetime_usec`, nilable) when some timeout
  in the workflow declares `repeat_until`. Unlike `state_entered_at`, a
  repeating timeout's own firing never touches it — see
  `AshWorkflow.Entities.Timeout` for why `repeat_until` needs an anchor that
  repeating cannot move. Nilable because it is a new column on what may be an
  existing table: an in-flight record written before this attribute existed has
  no value for it until it next enters a step, and `repeat_until` treats that
  as "bound not yet reached" rather than raising.
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
          writable?: true,
          public?: true
        )

      _exists ->
        {:ok, dsl}
    end
  end

  defp add_repeat_started_at(dsl) do
    if any_repeat_until?(dsl) and ResourceInfo.attribute(dsl, :repeat_started_at) == nil do
      Builder.add_attribute(dsl, :repeat_started_at, :utc_datetime_usec,
        allow_nil?: true,
        writable?: true,
        public?: true
      )
    else
      {:ok, dsl}
    end
  end

  defp any_repeat_until?(dsl) do
    dsl
    |> DslTransformer.get_entities([:workflow])
    |> Enum.filter(&match?(%Step{}, &1))
    |> Enum.any?(fn step -> Enum.any?(step.timeouts, & &1.repeat_until) end)
  end

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
