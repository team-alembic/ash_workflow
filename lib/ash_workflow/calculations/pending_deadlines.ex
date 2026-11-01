defmodule AshWorkflow.Calculations.PendingDeadlines do
  @moduledoc """
  Ash calculation listing the timeouts and `every` entries still ahead of a
  record in its current step, soonest first.

  Each entry is a map with `:name`, `:due_at`, `:kind` (`:action`,
  `:transition` or `:every`) and `:target` (the destination step for
  transition timeouts, `nil` otherwise).

  ## What this is not

  This is the schedule *implied* by the DSL and the record's current field
  values — `field + fire_after`, or the `fire_at` field itself, computed on read.

  A deadline leaves the list once it has fired. A transition timeout changes
  the state when it fires. An action timeout does not, so its entry is omitted
  while its `<step>_<timeout>_fired_at` column holds an instant at or after
  its `due_at`. A timeout that is due but has not fired yet still appears with
  a `due_at` in the past.

  Firing an `every` writes its own last-fired column, so its `due_at` is
  always the next instant it will run.

  An `every` with `backoff` reports the grown gap, and one that has used up
  its `max_fires` in the current step visit is omitted.

  A timeout whose `field` is `nil` on the record has no derivable deadline and
  is omitted. An `every` whose column is `nil` is different: it has never
  fired, and its interval is measured from `state_entered_at` instead — see
  `AshWorkflow.Entities.Every` — so its entry reports one whole interval after
  the record entered the step, rather than being omitted.
  """
  use Ash.Resource.Calculation

  alias AshWorkflow.Entities.Every

  @impl true
  @spec init(Keyword.t()) :: {:ok, Keyword.t()}
  def init(opts), do: {:ok, opts}

  @impl true
  @spec load(Ash.Query.t(), Keyword.t(), map()) :: [atom()]
  def load(_query, opts, _context) do
    fields =
      opts[:timeouts]
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(
        &([
            &1.field
            | List.wrap(Map.get(&1, :fired_field)) ++ List.wrap(Map.get(&1, :fires_field))
          ] ++
            time_zone_field(&1))
      )
      |> Enum.uniq()

    [Keyword.fetch!(opts, :state_attribute), :state_entered_at | fields]
  end

  # A wall-clock `every` whose `time_zone` names an attribute cannot compute an
  # occurrence without reading it.
  defp time_zone_field(%{wall_clock: %AshWorkflow.WallClock{time_zone: zone}})
       when is_atom(zone) and not is_nil(zone),
       do: [zone]

  defp time_zone_field(_entry), do: []

  @impl true
  @spec calculate([Ash.Resource.record()], Keyword.t(), map()) :: [[map()]]
  def calculate(records, opts, _context) do
    state_attribute = Keyword.fetch!(opts, :state_attribute)

    Enum.map(records, fn record ->
      opts[:timeouts]
      |> Map.get(Map.get(record, state_attribute), [])
      |> Enum.flat_map(&deadline(&1, record))
      |> Enum.sort_by(& &1.due_at, DateTime)
    end)
  end

  # A never-fired `every` measures its interval from `state_entered_at`, the
  # same fallback `AshWorkflow.Transformers.AddScheduler` compiles into the
  # trigger's `where`.
  # A wall-clock `every` reports the first occurrence of its local time after
  # the later of its last fire and entry. A last fire from an earlier visit to
  # the step is older than entry, so it does not make the record due. A record naming a
  # zone the time zone database does not know has no computable occurrence and
  # is omitted, the same way a nil timeout field is.
  defp deadline(
         %{kind: :every, wall_clock: %AshWorkflow.WallClock{} = wall_clock} = every,
         record
       ) do
    last_fired_at = as_datetime(Map.get(record, every.field))
    state_entered_at = as_datetime(Map.get(record, :state_entered_at))
    fires = every.fires_field && Map.get(record, every.fires_field)

    from = later(last_fired_at, state_entered_at)

    time_zone = AshWorkflow.WallClock.time_zone_for(wall_clock, record)

    cond do
      is_nil(state_entered_at) or exhausted?(every, last_fired_at, fires, state_entered_at) ->
        []

      due_at = from && AshWorkflow.WallClock.next_occurrence(wall_clock, time_zone, from) ->
        [entry(every, due_at)]

      true ->
        []
    end
  end

  defp deadline(%{kind: :every} = every, record) do
    last_fired_at = as_datetime(Map.get(record, every.field))
    state_entered_at = as_datetime(Map.get(record, :state_entered_at))
    fires = every.fires_field && Map.get(record, every.fires_field)

    cond do
      is_nil(state_entered_at) ->
        []

      exhausted?(every, last_fired_at, fires, state_entered_at) ->
        []

      true ->
        due_at =
          Every.next_due_at(
            every.fire_after,
            every.backoff,
            last_fired_at,
            fires,
            state_entered_at
          )

        [entry(every, due_at)]
    end
  end

  defp deadline(timeout, record) do
    with %DateTime{} = from <- as_datetime(Map.get(record, timeout.field)),
         {:ok, true} <-
           Ash.Expr.eval(timeout.not_fired, record: record, resource: record.__struct__) do
      [entry(timeout, due_at(from, timeout.fire_after))]
    else
      nil -> []
      {:ok, false} -> []
    end
  end

  defp later(nil, other), do: other
  defp later(other, nil), do: other
  defp later(left, right), do: Enum.max([left, right], DateTime)

  defp exhausted?(%{max_fires: nil}, _last_fired_at, _fires, _state_entered_at), do: false
  defp exhausted?(_every, nil, _fires, _state_entered_at), do: false

  defp exhausted?(%{max_fires: max_fires}, last_fired_at, fires, state_entered_at) do
    DateTime.compare(last_fired_at, state_entered_at) != :lt and (fires || 0) >= max_fires
  end

  defp entry(timeout, due_at) do
    %{name: timeout.name, due_at: due_at, kind: timeout.kind, target: timeout.target}
  end

  # A `fire_at` timeout carries no duration: its field holds the deadline itself.
  defp due_at(from, nil), do: from
  defp due_at(from, {value, unit}), do: DateTime.add(from, value, singular_unit(unit))

  # Timeout fields are verified to be a datetime type, but that includes the
  # naive variants, which have no zone to compare against.
  defp as_datetime(%DateTime{} = value), do: value
  defp as_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp as_datetime(nil), do: nil

  defp singular_unit(:days), do: :day
  defp singular_unit(:hours), do: :hour
  defp singular_unit(:minutes), do: :minute
  defp singular_unit(:seconds), do: :second
end
