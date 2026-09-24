defmodule AshWorkflow.Transformers.AddRelationships do
  @moduledoc """
  Adds a public `has_many :transitions` relationship to the `transition_log`
  resource when one is configured.

  Uses `add_new_relationship`, so a user-defined `:transitions` relationship
  takes precedence.
  """
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    with %{resource: log_resource} <- AshWorkflow.Info.transition_log(dsl),
         {:ok, foreign_key} <-
           log_foreign_key(log_resource, Transformer.get_persisted(dsl, :module)) do
      Builder.add_new_relationship(dsl, :has_many, :transitions, log_resource,
        destination_attribute: foreign_key,
        public?: true
      )
    else
      _ -> {:ok, dsl}
    end
  end

  # Compiling the log from here does not deadlock: its `belongs_to` does not
  # need the workflow compiled. An unusable log adds nothing, so that
  # `AshWorkflow.Verifiers.ValidateTransitionLog` reports why.
  defp log_foreign_key(log_resource, workflow_resource) do
    if Ash.Resource.Info.resource?(log_resource) do
      log_resource
      |> Ash.Resource.Info.relationships()
      |> Enum.find(&(&1.type == :belongs_to and &1.destination == workflow_resource))
      |> case do
        nil -> :error
        relationship -> {:ok, relationship.source_attribute}
      end
    else
      :error
    end
  end

  def before?(Ash.Resource.Transformers.SetRelationshipSource), do: true
  def before?(Ash.Resource.Transformers.CacheRelationships), do: true
  def before?(_), do: false
end
