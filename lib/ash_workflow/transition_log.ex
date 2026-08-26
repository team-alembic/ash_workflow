defmodule AshWorkflow.TransitionLog do
  @moduledoc """
  Runtime helpers shared by `AshWorkflow.Changes.RecordEvent` and the
  generated `state_at/2` and `history/1` code interface functions.

  Kept out of the generated functions themselves so the injected code (via
  `Spark.Dsl.Transformer.eval/3`) stays a thin delegate, and so this logic is
  directly unit-testable.
  """

  alias AshWorkflow.Info

  @doc """
  Returns the transition log rows for `record`, ordered by `occurred_at`
  ascending.

  Raises if the resource has no `transition_log` configured.
  """
  @spec history(Ash.Resource.record()) :: [Ash.Resource.record()]
  def history(record) do
    resource = record.__struct__
    log = fetch_log!(resource)
    foreign_key = foreign_key!(log.resource, resource)
    primary_key_value = primary_key_value!(record)

    log.resource
    |> Ash.Query.do_filter([{foreign_key, primary_key_value}])
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  @doc """
  Returns the state `record` was in at `at`, resolved by walking its
  transition log in Elixir. Portable across data layers because it does not
  rely on a "latest row per record" query.

  Returns `nil` if `at` is before the earliest logged row.
  """
  @spec state_at(Ash.Resource.record(), DateTime.t()) :: atom() | nil
  def state_at(record, at) do
    record
    |> history()
    |> Enum.filter(&(DateTime.compare(&1.occurred_at, at) != :gt))
    |> Enum.max_by(& &1.occurred_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      row -> row.to_state
    end
  end

  @doc false
  @spec fetch_log!(Ash.Resource.t()) :: AshWorkflow.Entities.TransitionLog.t()
  def fetch_log!(resource) do
    case Info.transition_log(resource) do
      nil ->
        raise ArgumentError,
              "#{inspect(resource)} has no `transition_log` configured in its `workflow` block."

      log ->
        log
    end
  end

  @doc false
  @spec foreign_key!(Ash.Resource.t(), Ash.Resource.t()) :: atom()
  def foreign_key!(log_resource, workflow_resource) do
    log_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == workflow_resource))
    |> case do
      nil ->
        raise ArgumentError,
              "#{inspect(log_resource)} has no belongs_to relationship to #{inspect(workflow_resource)}."

      relationship ->
        relationship.source_attribute
    end
  end

  @doc false
  @spec foreign_key_for_relationship!(Ash.Resource.t(), atom()) :: atom()
  def foreign_key_for_relationship!(log_resource, relationship_name) do
    log_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == relationship_name))
    |> case do
      nil ->
        raise ArgumentError,
              "#{inspect(log_resource)} has no belongs_to relationship named :#{relationship_name}."

      relationship ->
        relationship.source_attribute
    end
  end

  @doc false
  @spec primary_key_value!(Ash.Resource.record()) :: term()
  def primary_key_value!(record) do
    case Ash.Resource.Info.primary_key(record.__struct__) do
      [primary_key] ->
        Map.fetch!(record, primary_key)

      primary_keys ->
        raise ArgumentError,
              "transition_log requires a single-attribute primary key, got: #{inspect(primary_keys)}"
    end
  end
end
