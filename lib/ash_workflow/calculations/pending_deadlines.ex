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
  It is not a record of what has already fired.

  For a transition timeout that distinction does not arise: firing changes the
  state, so the deadline leaves the list. But a non-repeating action timeout
  does not change state, so its deadline keeps being derivable after it has
  fired, and it will still appear here with a `due_at` in the past. Read a past
  `due_at` as "was due", not "will fire".

  An `every` entry does not have the stale-past-`due_at` problem a
  non-repeating action timeout has: firing an `every` writes its own
  last-fired column, so its `due_at` is always the next instant it will run.

  A timeout whose `field` is `nil` on the record has no derivable deadline and
  is omitted. An `every` whose column is `nil` is different: it has never
  fired, and its interval is measured from `state_entered_at` instead — see
  `AshWorkflow.Entities.Every` — so its entry reports one whole interval after
  the record entered the step, rather than being omitted.
  """
  use Ash.Resource.Calculation

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
      |> Enum.flat_map(&[&1.field | time_zone_field(&1)])
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
  # the last fire, or after entry when it has never fired. A record naming a
  # zone the time zone database does not know has no computable occurrence and
  # is omitted, the same way a nil timeout field is.
  defp deadline(
         %{kind: :every, wall_clock: %AshWorkflow.WallClock{} = wall_clock} = every,
         record
       ) do
    from =
      as_datetime(Map.get(record, every.field)) ||
        as_datetime(Map.get(record, :state_entered_at))

    time_zone = AshWorkflow.WallClock.time_zone_for(wall_clock, record)

    case from && AshWorkflow.WallClock.next_occurrence(wall_clock, time_zone, from) do
      nil -> []
      due_at -> [entry(every, due_at)]
    end
  end

  defp deadline(%{kind: :every} = every, record) do
    from =
      as_datetime(Map.get(record, every.field)) ||
        as_datetime(Map.get(record, :state_entered_at))

    case from do
      nil -> []
      from -> [entry(every, due_at(from, every.fire_after))]
    end
  end

  defp deadline(timeout, record) do
    case as_datetime(Map.get(record, timeout.field)) do
      nil -> []
      from -> [entry(timeout, due_at(from, timeout.fire_after))]
    end
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
