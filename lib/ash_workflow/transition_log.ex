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

  ## Options

    * `:effective` — when `true`, omits rows that a later undo reversed,
      leaving the corrected account of what stands rather than the full record
      of what happened. Defaults to `false`.
  """
  @spec history(Ash.Resource.record(), Keyword.t()) :: [Ash.Resource.record()]
  def history(record, opts \\ []) do
    resource = record.__struct__
    log = fetch_log!(resource)
    foreign_key = foreign_key!(log.resource, resource)
    primary_key_value = primary_key_value!(record)

    rows =
      log.resource
      |> Ash.Query.do_filter([{foreign_key, primary_key_value}])
      |> Ash.Query.sort(occurred_at: :asc)
      |> Ash.read!(authorize?: false)

    if opts[:effective], do: effective(rows), else: rows
  end

  @doc """
  Drops every row that a later undo reversed.

  An undo row carries `undoes_id` pointing at the row it reverses, so the
  superseded set is just the non-nil `undoes_id` values. Redo falls out of the
  same rule without a special case: undoing an undo marks the undo row itself
  superseded, which leaves the redo row — and the state it lands on — standing.
  """
  @spec effective([Ash.Resource.record()]) :: [Ash.Resource.record()]
  def effective([]), do: []

  def effective([row | _] = rows) do
    case undoes_foreign_key(row.__struct__) do
      nil ->
        rows

      undoes_key ->
        superseded =
          rows
          |> Enum.map(&Map.get(&1, undoes_key))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        Enum.reject(rows, &MapSet.member?(superseded, primary_key_value!(&1)))
    end
  end

  @doc """
  Returns the most recent row representing an actual state change, or `nil` if
  there is none.

  Rows where `from_state == to_state` are skipped: a repeating timeout writes
  one to re-arm its own trigger, and it did not move the workflow anywhere, so
  it is not what an undo should reverse.
  """
  @spec head_state_change(Ash.Resource.record()) :: Ash.Resource.record() | nil
  def head_state_change(record) do
    record
    |> history()
    |> Enum.filter(&(&1.from_state != &1.to_state))
    |> List.last()
  end

  @doc """
  Returns the state `record` was in at `at`, resolved by walking its
  transition log in Elixir. Portable across data layers because it does not
  rely on a "latest row per record" query.

  Returns `nil` if `at` is before the earliest logged row.

  ## Options

    * `:effective` — when `true`, answers from the corrected account rather
      than the literal one: rows reversed by a later undo are ignored, so a
      state the workflow briefly occupied and then rewound out of is not
      reported. Every known correction is applied regardless of when it
      happened, so this is "what we now say was true at `at`", not "what the
      log said at `at`". Defaults to `false`.
  """
  @spec state_at(Ash.Resource.record(), DateTime.t(), Keyword.t()) :: atom() | nil
  def state_at(record, at, opts \\ []) do
    record
    |> history(opts)
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

  @doc """
  Returns the `undoes` self-referencing foreign key on `log_resource`, or `nil`
  if the log does not declare one.
  """
  @spec undoes_foreign_key(Ash.Resource.t()) :: atom() | nil
  def undoes_foreign_key(log_resource) do
    log_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :undoes))
    |> case do
      nil -> nil
      relationship -> relationship.source_attribute
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
