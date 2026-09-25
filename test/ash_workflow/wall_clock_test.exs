defmodule AshWorkflow.WallClockTest do
  @moduledoc """
  The occurrence arithmetic behind `every ... at`.

  `AshWorkflow.Scheduler.Precise` and
  `AshWorkflow.Calculations.PendingDeadlines` both read these two functions,
  and the polled Oban trigger's `where` clause has to agree with them. The
  daylight saving cases below are the ones a Postgres `AT TIME ZONE` gets to
  decide on its own, so they are pinned here.
  """
  use ExUnit.Case, async: true

  alias AshWorkflow.WallClock

  defp weekdays(time, zone) do
    {:ok, days} = WallClock.to_day_numbers([:mon, :tue, :wed, :thu, :fri])

    %WallClock{time: time, days: days, time_zone: zone}
  end

  defp daily(time, zone) do
    {:ok, days} = WallClock.to_day_numbers(WallClock.day_names())

    %WallClock{time: time, days: days, time_zone: zone}
  end

  defp utc(iso), do: iso |> DateTime.from_iso8601() |> elem(1)

  describe "to_day_numbers/1" do
    test "maps day names to ISO numbers, sorted and deduplicated" do
      assert WallClock.to_day_numbers([:sun, :mon, :mon]) == {:ok, [1, 7]}
    end

    test "names the day it does not recognise" do
      assert WallClock.to_day_numbers([:mon, :caturday]) == {:error, :caturday}
    end
  end

  describe "next_occurrence/3" do
    test "finds today's occurrence when it is still ahead" do
      schedule = daily(~T[09:00:00], "Australia/Sydney")

      # 2026-03-02 is a Monday. 08:00 Sydney is 21:00 UTC the day before.
      assert WallClock.next_occurrence(schedule, "Australia/Sydney", utc("2026-03-01T21:00:00Z")) ==
               DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Australia/Sydney")
    end

    test "rolls to tomorrow once today's occurrence has passed" do
      schedule = daily(~T[09:00:00], "Australia/Sydney")

      assert WallClock.next_occurrence(schedule, "Australia/Sydney", utc("2026-03-01T23:00:00Z")) ==
               DateTime.new!(~D[2026-03-03], ~T[09:00:00], "Australia/Sydney")
    end

    test "skips the days `on` does not list" do
      schedule = weekdays(~T[09:00:00], "Australia/Sydney")

      # Saturday 2026-03-07, local afternoon.
      from = DateTime.new!(~D[2026-03-07], ~T[14:00:00], "Australia/Sydney")

      assert WallClock.next_occurrence(schedule, "Australia/Sydney", from) ==
               DateTime.new!(~D[2026-03-09], ~T[09:00:00], "Australia/Sydney")
    end

    test "two records in the same step fire at different instants in different zones" do
      schedule = daily(~T[09:00:00], :zone_attribute)
      from = utc("2026-03-01T00:00:00Z")

      sydney = WallClock.next_occurrence(schedule, "Australia/Sydney", from)
      london = WallClock.next_occurrence(schedule, "Europe/London", from)

      assert DateTime.to_time(sydney) == ~T[09:00:00]
      assert DateTime.to_time(london) == ~T[09:00:00]
      refute DateTime.compare(sydney, london) == :eq
    end

    test "returns nil for a zone the time zone database does not know" do
      schedule = daily(~T[09:00:00], :zone_attribute)

      assert WallClock.next_occurrence(schedule, "Mars/Olympus_Mons", utc("2026-03-01T00:00:00Z")) ==
               nil
    end

    test "returns nil when the record's zone attribute is empty" do
      schedule = daily(~T[09:00:00], :zone_attribute)

      assert WallClock.next_occurrence(schedule, nil, utc("2026-03-01T00:00:00Z")) == nil
    end
  end

  describe "previous_occurrence/3" do
    test "is today's occurrence once it has passed" do
      schedule = daily(~T[09:00:00], "Australia/Sydney")
      now = DateTime.new!(~D[2026-03-02], ~T[11:00:00], "Australia/Sydney")

      assert WallClock.previous_occurrence(schedule, "Australia/Sydney", now) ==
               DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Australia/Sydney")
    end

    test "is the previous listed day when today is not one" do
      schedule = weekdays(~T[09:00:00], "Australia/Sydney")
      now = DateTime.new!(~D[2026-03-08], ~T[11:00:00], "Australia/Sydney")

      assert WallClock.previous_occurrence(schedule, "Australia/Sydney", now) ==
               DateTime.new!(~D[2026-03-06], ~T[09:00:00], "Australia/Sydney")
    end
  end

  describe "stride" do
    defp strided(time, zone, stride) do
      {:ok, days} = WallClock.to_day_numbers(WallClock.day_names())

      %WallClock{time: time, days: days, time_zone: zone, stride: stride}
    end

    test "skips occurrences closer than the stride" do
      schedule = strided(~T[09:00:00], "Etc/UTC", 2)
      from = DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Etc/UTC")

      assert WallClock.next_occurrence(schedule, "Etc/UTC", from) ==
               DateTime.new!(~D[2026-03-04], ~T[09:00:00], "Etc/UTC")
    end

    test "counts local dates, so a fire a microsecond late does not slip a day" do
      schedule = strided(~T[09:00:00], "Etc/UTC", 2)

      from =
        ~D[2026-03-02]
        |> DateTime.new!(~T[09:00:00], "Etc/UTC")
        |> DateTime.add(1, :microsecond)

      assert DateTime.to_date(WallClock.next_occurrence(schedule, "Etc/UTC", from)) ==
               ~D[2026-03-04]
    end

    test "a stride longer than a week still finds an occurrence" do
      {:ok, days} = WallClock.to_day_numbers([:mon])
      schedule = %WallClock{time: ~T[09:00:00], days: days, time_zone: "Etc/UTC", stride: 14}
      from = DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Etc/UTC")

      assert WallClock.next_occurrence(schedule, "Etc/UTC", from) ==
               DateTime.new!(~D[2026-03-16], ~T[09:00:00], "Etc/UTC")
    end

    test "a stride that lands on a day `on` does not list waits for one that is listed" do
      {:ok, days} = WallClock.to_day_numbers([:mon])
      schedule = %WallClock{time: ~T[09:00:00], days: days, time_zone: "Etc/UTC", stride: 10}
      from = DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Etc/UTC")

      # Ten days on is a Thursday, which `on` does not list, so the first
      # eligible occurrence is the Monday after.
      assert WallClock.next_occurrence(schedule, "Etc/UTC", from) ==
               DateTime.new!(~D[2026-03-16], ~T[09:00:00], "Etc/UTC")
    end

    test "no stride leaves today's occurrence eligible" do
      schedule = strided(~T[09:00:00], "Etc/UTC", nil)
      from = DateTime.new!(~D[2026-03-02], ~T[08:00:00], "Etc/UTC")

      assert WallClock.next_occurrence(schedule, "Etc/UTC", from) ==
               DateTime.new!(~D[2026-03-02], ~T[09:00:00], "Etc/UTC")
    end

    test "previous_occurrence describes the grid, ignoring the stride" do
      now = DateTime.new!(~D[2026-03-03], ~T[12:00:00], "Etc/UTC")

      assert WallClock.previous_occurrence(strided(~T[09:00:00], "Etc/UTC", 14), "Etc/UTC", now) ==
               DateTime.new!(~D[2026-03-03], ~T[09:00:00], "Etc/UTC")
    end
  end

  describe "daylight saving" do
    # Australia/Lord_Howe moves 02:00 -> 02:30 on the first Sunday in October,
    # so 02:15 local does not exist that day.
    test "a skipped local time still fires, at the instant the clock jumps to" do
      schedule = daily(~T[02:15:00], "Australia/Lord_Howe")
      from = DateTime.new!(~D[2026-10-03], ~T[12:00:00], "Australia/Lord_Howe")

      occurrence = WallClock.next_occurrence(schedule, "Australia/Lord_Howe", from)

      assert DateTime.to_date(occurrence) == ~D[2026-10-04],
             "the day must not be skipped just because the local time does not exist"

      assert DateTime.to_time(occurrence) == ~T[02:30:00]
    end

    # Australia/Lord_Howe moves 02:00 -> 01:30 on the first Sunday in April, so
    # 01:45 local happens twice.
    test "a doubled local time fires on the first of its two instants" do
      schedule = daily(~T[01:45:00], "Australia/Lord_Howe")
      from = DateTime.new!(~D[2026-04-04], ~T[12:00:00], "Australia/Lord_Howe")

      occurrence = WallClock.next_occurrence(schedule, "Australia/Lord_Howe", from)

      {:ambiguous, first, second} =
        DateTime.new(~D[2026-04-05], ~T[01:45:00], "Australia/Lord_Howe")

      assert occurrence == first
      refute occurrence == second
    end

    test "the second instant of a doubled local time is not a second occurrence" do
      schedule = daily(~T[01:45:00], "Australia/Lord_Howe")

      {:ambiguous, first, second} =
        DateTime.new(~D[2026-04-05], ~T[01:45:00], "Australia/Lord_Howe")

      # The last fire landed on the first instant, so nothing fires again until
      # the next day.
      occurrence = WallClock.next_occurrence(schedule, "Australia/Lord_Howe", first)

      assert DateTime.after?(occurrence, second)
      assert DateTime.to_date(occurrence) == ~D[2026-04-06]
    end
  end

  describe "time_zone_for/2" do
    test "returns a literal zone unchanged" do
      assert WallClock.time_zone_for(daily(~T[09:00:00], "Etc/UTC"), %{}) == "Etc/UTC"
    end

    test "reads an attribute off the record" do
      schedule = daily(~T[09:00:00], :candidate_time_zone)

      assert WallClock.time_zone_for(schedule, %{candidate_time_zone: "Europe/London"}) ==
               "Europe/London"
    end

    test "is nil when the attribute is unset" do
      schedule = daily(~T[09:00:00], :candidate_time_zone)

      assert WallClock.time_zone_for(schedule, %{candidate_time_zone: nil}) == nil
    end
  end
end
