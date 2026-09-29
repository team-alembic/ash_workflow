defmodule AshWorkflow.Routing do
  @moduledoc false
  # Resolves the step a manual transition moves a record to. The generated
  # transition action (`AshWorkflow.Changes.ConditionalTransition`) and
  # `AshWorkflow.Info.transition_target/3` both go through here, so a preview
  # and the real transition cannot disagree.

  alias AshWorkflow.Entities.Route

  require Ash.Expr

  @doc """
  Scopes each of a merged transition's routes to the step it leaves.

  Takes the `routes` of `AshWorkflow.Info.transition/2`. A static route's
  `when` is `nil`, so it becomes the step guard alone.
  """
  @spec guarded_routes([%{from: atom(), to: atom(), when: Ash.Expr.t() | nil}], atom()) ::
          [Route.t()]
  def guarded_routes(routes, state_attribute) do
    Enum.map(routes, fn route ->
      in_step = Ash.Expr.expr(^Ash.Expr.ref(state_attribute) == ^route.from)

      condition =
        case route.when do
          nil -> in_step
          condition -> Ash.Expr.expr(^in_step and ^condition)
        end

      %Route{to: route.to, when: condition}
    end)
  end

  @doc """
  The record as loaded, with the accepted attributes of `input` applied.
  """
  @spec with_input(Ash.Resource.record(), map(), [atom()]) :: Ash.Resource.record()
  def with_input(record, input, accept), do: Map.merge(record, Map.take(input, accept))

  @doc """
  Evaluates `routes` in order against `record` and returns the first match.
  """
  @spec match([Route.t()], Ash.Resource.record(), Ash.Resource.t()) ::
          {:ok, atom()} | :no_match | {:error, Route.t(), term()}
  def match(routes, record, resource) do
    Enum.reduce_while(routes, :no_match, fn route, _acc ->
      case Ash.Expr.eval(route.when, record: record, resource: resource) do
        {:ok, true} -> {:halt, {:ok, route.to}}
        {:ok, _} -> {:cont, :no_match}
        {:error, error} -> {:halt, {:error, route, error}}
      end
    end)
  end
end
