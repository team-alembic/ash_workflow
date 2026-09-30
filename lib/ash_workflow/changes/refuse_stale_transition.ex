defmodule AshWorkflow.Changes.RefuseStaleTransition do
  @moduledoc """
  Refuses a transition built from a stale record: the update writes only if
  the row still holds the values the transition decided from.

  The values are the state attribute and every attribute of the resource that
  the routes of the loaded step read. When the row no longer holds one of
  them, the update fails with `Ash.Error.Changes.StaleRecord` and the row is
  left as it was.

  An attribute the call supplies through the transition's `accept` is not
  pinned, since a route reads the supplied value, not the loaded one.
  References through a relationship, and calculations or aggregates, are not
  pinned: they are not values on the row.

  On a data layer that cannot filter an update, such as
  `Ash.DataLayer.Simple`, `Ash.Changeset.filter/2` drops the filter, so
  nothing is pinned.

  `AshWorkflow.Transformers.AddActions` adds it to each manual transition and
  to `undo`. Not intended for direct use.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.StaleRecord
  alias AshWorkflow.Info
  alias AshWorkflow.Routing

  require Ash.Expr

  # A filtered update that matches no rows returns `StaleRecord`.
  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> pins(opts)
    |> Enum.reduce(changeset, fn {field, value}, changeset ->
      Ash.Changeset.filter(changeset, equals_loaded(field, value))
    end)
  end

  # Ash does not carry a filter added here into the atomic update, so the
  # check is an atomic validation that raises `StaleRecord` instead.
  @impl true
  def atomic(changeset, opts, _context) do
    case changeset.data do
      # An update over a query reads each row in the statement that writes it.
      %Ash.Changeset.OriginalDataNotAvailable{} ->
        {:ok, changeset}

      _record ->
        pins = pins(changeset, opts)

        loaded =
          Enum.reduce(pins, true, fn {field, value}, loaded ->
            Ash.Expr.expr(^loaded and ^equals_loaded(field, value))
          end)

        stale =
          Ash.Expr.expr(
            error(StaleRecord, %{
              resource: ^inspect(changeset.resource),
              filter: ^Map.new(pins)
            })
          )

        {:atomic, %{}, [{:atomic, [], Ash.Expr.expr(not (^loaded)), stale}]}
    end
  end

  defp pins(changeset, opts) do
    changeset
    |> pinned_fields(opts)
    |> Enum.map(&{&1, Map.get(changeset.data, &1)})
    # A field the caller did not select was not read, so nothing decided from it.
    |> Enum.reject(&match?({_field, %Ash.NotLoaded{}}, &1))
  end

  defp pinned_fields(changeset, opts) do
    resource = changeset.resource
    state_attribute = Info.state_attribute(resource)
    supplied = changeset.attributes |> Map.take(opts[:accept] || []) |> Map.keys()

    route_fields =
      opts[:transition_name]
      |> routes_from(resource, Map.get(changeset.data, state_attribute))
      |> Enum.flat_map(&Routing.references(&1.when, resource))
      |> Enum.filter(&own_attribute?/1)
      |> Enum.map(& &1.attribute.name)

    Enum.uniq([state_attribute | route_fields -- supplied])
  end

  defp routes_from(nil, _resource, _state), do: []

  defp routes_from(transition_name, resource, state) do
    resource
    |> Info.transition(transition_name)
    |> Map.fetch!(:routes)
    |> Enum.filter(&(&1.from == state))
  end

  defp own_attribute?(%Ash.Query.Ref{relationship_path: [], attribute: attribute}),
    do: match?(%Ash.Resource.Attribute{}, attribute)

  defp own_attribute?(_ref), do: false

  defp equals_loaded(field, nil), do: Ash.Expr.expr(is_nil(^Ash.Expr.ref(field)))
  defp equals_loaded(field, value), do: Ash.Expr.expr(^Ash.Expr.ref(field) == ^value)
end
