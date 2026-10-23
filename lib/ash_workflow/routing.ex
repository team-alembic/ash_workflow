defmodule AshWorkflow.Routing do
  @moduledoc false
  # Resolves the step a manual transition moves a record to. The generated
  # transition action (`AshWorkflow.Changes.ConditionalTransition`) and
  # `AshWorkflow.Info.transition_target/3` both go through here, so a preview
  # and the real transition cannot disagree. `references/2` is shared by the
  # `:transition_targets` loads and `AshWorkflow.Changes.RefuseStaleTransition`.

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

  @doc """
  The fields a route condition references, as hydrated `Ash.Query.Ref`s.

  A reference through a relationship keeps its `relationship_path`. A
  condition that does not hydrate references nothing.
  """
  @spec references(Ash.Expr.t() | nil, Ash.Resource.t()) :: [struct()]
  def references(nil, _resource), do: []

  def references(condition, resource) do
    case Ash.Filter.hydrate_refs(condition, %{resource: resource}) do
      {:ok, hydrated} -> Ash.Filter.list_refs(hydrated)
      {:error, _error} -> []
    end
  end

  @doc """
  The load statement for a reference: `relationship.field` becomes
  `{:relationship, [:field]}`.
  """
  @spec load_path(struct()) :: atom() | tuple()
  def load_path(%Ash.Query.Ref{relationship_path: path, attribute: attribute}) do
    List.foldr(path, field_name(attribute), &{&1, [&2]})
  end

  @doc """
  Loads the calculations, aggregates and related fields `routes` reference
  onto `record`, so a condition does not read them as unloaded.
  """
  @spec load_references(Ash.Resource.record(), [Route.t()], keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def load_references(%resource{} = record, routes, opts) do
    routes
    |> Enum.flat_map(&references(&1.when, resource))
    |> Enum.reject(&own_attribute?/1)
    |> Enum.map(&load_path/1)
    |> Enum.uniq()
    |> case do
      [] -> {:ok, record}
      loads -> Ash.load(record, loads, opts)
    end
  end

  defp own_attribute?(%Ash.Query.Ref{relationship_path: [], attribute: attribute}),
    do: match?(%Ash.Resource.Attribute{}, attribute)

  defp own_attribute?(_ref), do: false

  defp field_name(%{name: name}), do: name
  defp field_name(name) when is_atom(name), do: name
end
