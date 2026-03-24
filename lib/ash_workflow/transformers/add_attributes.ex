defmodule AshWorkflow.Transformers.AddAttributes do
  @moduledoc """
  Adds the `state_entered_at` attribute if not already defined on the resource.

  This attribute tracks when the workflow entered its current state. It is used by
  timeout triggers to calculate whether a deadline has passed. The attribute is:

  - Type: `:utc_datetime_usec`
  - `allow_nil?: true` (nil before the workflow starts)
  - `public?: true` and `writable?: true`

  Does NOT add the `:state` attribute — that is handled by
  `AshStateMachine.Transformers.AddState`.

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
          allow_nil?: true,
          writable?: true,
          public?: true
        )

      _exists ->
        {:ok, dsl}
    end
  end

  def before?(AshStateMachine.Transformers.AddState), do: true
  def before?(_), do: false
end
