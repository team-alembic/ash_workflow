defmodule AshWorkflow.WallClock do
  @moduledoc """
  The wall-clock schedule an `every` declares with `at`, `on` and `time_zone`.

  An `every` with an `interval` measures from its own last fire, so a daily
  one drifts to whatever time the record entered the step. A wall-clock
  `every` names the local time instead:

      every :daily_digest do
        at ~T[09:00:00]
        on [:mon, :tue, :wed, :thu, :fri]
        time_zone :candidate_time_zone
        action :send_digest
      end

  `time_zone` takes a literal such as `"Australia/Sydney"`, an attribute on
  the record, or an expression calculation — which is how a record reads its
  zone off a related one, with
  `calculate :candidate_time_zone, :string, expr(candidate.time_zone)`. A
  per-record zone is the case a global cron cannot express, and it is why the
  trigger's `where` clause reads the zone out of the row rather than out of
  the DSL.

  `time_zone_for/2` resolves all three against a record. A calculation has to
  have been loaded first, which `AshWorkflow.Scheduler.Precise.Timeline` and
  `AshWorkflow.Calculations.PendingDeadlines` both arrange.

  ## `stride`

  `on` says which days are occurrences. `stride` says how many local days
  must separate the last fire from the next one, and comes from an `interval`
  declared alongside `at`:

      every :fortnightly_digest do
        interval {14, :days}
        at ~T[09:00:00]
        on [:mon]
        time_zone :candidate_time_zone
        action :send_digest
      end

  A stride counts local dates rather than elapsed duration. Firing at 09:00
  writes the last-fired column a moment after 09:00, so `last_fire + 14 days`
  falls microseconds after the occurrence exactly fourteen days later, and a
  duration comparison would skip it and wait another week. `Date.diff/2` has
  no such margin, and no daylight saving exposure either.

  A record that has never fired has no last fire to measure the stride from,
  so the stride is measured from `state_entered_at` instead. The first firing
  then lands one whole stride after entry, which is what an `interval` every
  does today.

  ## Two readers, one schedule

  `AshWorkflow.Transformers.AddScheduler` compiles this into a Postgres
  `fragment` for the polled trigger, which answers "is this record due now".
  This module answers the other question — "when is this record next due" —
  in Elixir, for `AshWorkflow.Scheduler.Precise` to arm a timer against and
  for `AshWorkflow.Calculations.PendingDeadlines` to report. Both readers
  agree on the two rules below.

  ## Daylight saving

  A local time that daylight saving skipped still fires that day, at the
  instant the clock jumps to. `~T[02:30:00]` on a day whose clocks go
  02:00 -> 03:00 fires at 03:00 local. Skipping the day instead would mean a
  digest silently missing one day a year, in whichever zones the row happens
  to name.

  A local time that happens twice fires on the first of the two instants.
  The second one is then no longer after the last fire, so nothing fires
  again.

  ## A missed occurrence fires late

  The trigger compares the last fire against the most recent occurrence, so a
  09:00 digest missed because nothing was polling goes out whenever polling
  resumes, as long as that is still the same local day. Once the local day
  rolls over, the missed occurrence is gone and the next one is tomorrow's.
  """

  defstruct [:time, :days, :time_zone, :stride]

  @type t :: %__MODULE__{
          time: Time.t(),
          days: [1..7],
          time_zone: atom() | String.t(),
          stride: pos_integer() | nil
        }

  @day_numbers %{mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 7}
  @week_days 7

  @doc """
  The day atoms `on` accepts, in ISO order.
  """
  @spec day_names() :: [atom()]
  def day_names, do: Map.keys(@day_numbers) |> Enum.sort_by(&@day_numbers[&1])

  @doc """
  Converts a list of day atoms to ISO day numbers, sorted and deduplicated.
  """
  @spec to_day_numbers([atom()]) :: {:ok, [1..7]} | {:error, atom()}
  def to_day_numbers(days) do
    Enum.reduce_while(days, {:ok, []}, fn day, {:ok, numbers} ->
      case Map.fetch(@day_numbers, day) do
        {:ok, number} -> {:cont, {:ok, [number | numbers]}}
        :error -> {:halt, {:error, day}}
      end
    end)
    |> case do
      {:ok, numbers} -> {:ok, numbers |> Enum.uniq() |> Enum.sort()}
      {:error, day} -> {:error, day}
    end
  end

  @doc """
  The time zone this schedule applies to for a given record.

  A literal zone is returned as-is. An attribute name is read off the record,
  so two records in the same step can fire at the same local time in
  different zones.
  """
  @spec time_zone_for(t(), Ash.Resource.record()) :: String.t() | nil
  def time_zone_for(%__MODULE__{time_zone: zone}, _record) when is_binary(zone), do: zone

  def time_zone_for(%__MODULE__{time_zone: attribute}, record) do
    case Map.get(record, attribute) do
      zone when is_binary(zone) -> zone
      _other -> nil
    end
  end

  @doc """
  The first occurrence strictly after `from`, or `nil` when the zone is
  unknown to the configured time zone database.

  `from` is the last fire, or `state_entered_at` for a record that has never
  fired, which is what puts the first firing on the first occurrence after
  the record entered the step rather than on entry.
  """
  @spec next_occurrence(t(), String.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def next_occurrence(_schedule, nil, _from), do: nil

  def next_occurrence(%__MODULE__{} = schedule, time_zone, from) do
    search(schedule, time_zone, from, 1, fn instant ->
      DateTime.after?(instant, from) and stride_clear?(schedule, time_zone, instant, from)
    end)
  end

  # `interval {14, :days}` alongside `at` counts local days between the last
  # fire and the candidate, not elapsed duration. Firing at 09:00 writes the
  # last-fired column a moment after 09:00, so a duration comparison would find
  # the occurrence exactly one stride later short by those microseconds and
  # slip a whole day. Two local dates subtract exactly.
  defp stride_clear?(%__MODULE__{stride: nil}, _time_zone, _instant, _from), do: true

  defp stride_clear?(%__MODULE__{stride: stride}, time_zone, instant, from) do
    case DateTime.shift_zone(from, time_zone) do
      {:ok, local_from} ->
        Date.diff(DateTime.to_date(instant), DateTime.to_date(local_from)) >= stride

      {:error, _reason} ->
        false
    end
  end

  @doc """
  The most recent occurrence at or before `now`, or `nil` when the zone is
  unknown to the configured time zone database.

  This is the boundary the polled trigger compares the last fire against. It
  describes the occurrence grid `at` and `on` lay down, so it ignores
  `stride` — a stride is a rule about the gap from the last fire, and this
  function is not given one.
  """
  @spec previous_occurrence(t(), String.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def previous_occurrence(_schedule, nil, _now), do: nil

  def previous_occurrence(%__MODULE__{} = schedule, time_zone, now) do
    search(schedule, time_zone, now, -1, &(not DateTime.after?(&1, now)))
  end

  # Walks local dates from the anchor's own local date, forwards or backwards,
  # and returns the first occurrence the caller accepts. A week past the stride
  # is enough for any `on`, since a schedule listing one day repeats every
  # seven and no candidate before the stride is eligible.
  defp search(schedule, time_zone, anchor, step, acceptable?) do
    case DateTime.shift_zone(anchor, time_zone) do
      {:ok, local} ->
        local
        |> DateTime.to_date()
        |> candidate_dates(schedule.days, step, (schedule.stride || 1) + @week_days)
        |> Enum.find_value(&accepted_instant(&1, schedule.time, time_zone, acceptable?))

      {:error, _reason} ->
        nil
    end
  end

  defp accepted_instant(date, time, time_zone, acceptable?) do
    instant = instant_on(date, time, time_zone)

    if instant && acceptable?.(instant), do: instant
  end

  defp candidate_dates(from_date, days, step, window) do
    0..window
    |> Enum.map(&Date.add(from_date, &1 * step))
    |> Enum.filter(&(Date.day_of_week(&1) in days))
  end

  # A gap resolves to the instant the clock jumped to, so the day still fires.
  # An ambiguous local time resolves to the first of its two instants.
  defp instant_on(date, time, time_zone) do
    case DateTime.new(date, time, time_zone) do
      {:ok, instant} -> instant
      {:ambiguous, first, _second} -> first
      {:gap, _just_before, just_after} -> just_after
      {:error, _reason} -> nil
    end
  end
end
