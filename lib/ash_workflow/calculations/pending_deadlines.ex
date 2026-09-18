defmodule AshWorkflow.Calculations.PendingDeadlines do
  @moduledoc """
  Ash calculation listing the timeouts and `every` entries still ahead of a
  record in its current step, soonest first.

  Each entry is a map with `:name`, `:due_at`, `:kind` (`:action`,
  `:transition` or `:every`) and `:target` (the destination step for
  transition timeouts, `nil` otherwise).

  ## What this is not

  This is the schedule *implied* by the DSL and the record's current field
  values — `field + fire_after`, computed on read. It is not a record of what has
  already fired.

  For a transition timeout that distinction does not arise: firing changes the
  state, so the deadline leaves the list. But a non-repeating action timeout
  does not change state, so its deadline keeps being derivable after it has
  fired, and it will still appear here with a `due_at` in the past. Read a past
  `due_at` as "was due", not "will fire".

  An `every` entry does not have this problem: firing an `every`'s action
  resets `state_entered_at`, so its `due_at` is always the next instant it will
  run, never a stale past one.

  A timeout whose `field` is `nil` on the record has no derivable deadline and
  is omitted.
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
      |> Enum.map(& &1.field)
      |> Enum.uniq()

    [Keyword.fetch!(opts, :state_attribute) | fields]
  end

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

  defp deadline(timeout, record) do
    case as_datetime(Map.get(record, timeout.field)) do
      nil ->
        []

      from ->
        {value, unit} = timeout.fire_after

        [
          %{
            name: timeout.name,
            due_at: DateTime.add(from, value, singular_unit(unit)),
            kind: timeout.kind,
            target: timeout.target
          }
        ]
    end
  end

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
