defmodule AshWorkflow.Info do
  @moduledoc """
  Introspection helpers for AshWorkflow resources.
  """

  @doc """
  Returns all workflow step entities for a resource.
  """
  @spec steps(Ash.Resource.t()) :: [AshWorkflow.Entities.Step.t()]
  def steps(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:workflow])
  end

  @doc """
  Returns a single workflow step by name, or `nil` if not found.
  """
  @spec step(Ash.Resource.t(), atom()) :: AshWorkflow.Entities.Step.t() | nil
  def step(resource, step_name) do
    Enum.find(steps(resource), &(&1.name == step_name))
  end

  @doc """
  Returns the list of user-facing action names available at a given step.

  For manual steps, returns the transition names. For automatic and terminal
  steps, returns an empty list.
  """
  @spec available_actions(Ash.Resource.t(), atom()) :: [atom()]
  def available_actions(resource, step_name) do
    case step(resource, step_name) do
      %{manual: true, transitions: transitions} ->
        Enum.map(transitions, & &1.name)

      _ ->
        []
    end
  end
end
