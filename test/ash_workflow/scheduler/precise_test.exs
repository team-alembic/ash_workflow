defmodule AshWorkflow.Scheduler.PreciseTest do
  @moduledoc """
  `AshWorkflow.Scheduler.Precise` arms a timer per deadline instead of polling,
  so what these tests check is that a deadline fires near its instant, that a
  deadline nothing armed is still recovered, and that neither path fires twice.

  Deadlines here are measured against `deadline_from` on
  `AshWorkflowTest.PreciseDeadlineWorkflow`, which lets a test place the
  deadline a couple of hundred milliseconds out rather than waiting a whole
  second for it.
  """
  use ExUnit.Case, async: false

  alias Ash.DataLayer.Ets
  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Leader
  alias AshWorkflow.Scheduler.Precise
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.PreciseDeadlineWorkflow
  alias AshWorkflowTest.PreciseTimeoutWorkflow
  alias Spark.Dsl.Extension

  @resource PreciseDeadlineWorkflow

  setup do
    on_exit(fn -> Ets.stop(@resource) end)

    :ok
  end

  defp candidate(deadline_from) do
    @resource
    |> Ash.Changeset.for_create(:create, %{title: "one", deadline_from: deadline_from})
    |> Ash.create!()
  end

  defp ago(ms), do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

  defp reload(record) do
    Ash.get!(@resource, record.id)
  end

  defp start_timeline(opts) do
    opts = Keyword.merge([resources: [@resource], look_ahead_ms: 60_000], opts)

    start_supervised!({Timeline, opts})
  end

  defp await_state(record, state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_state(record, state, deadline, nil)
  end

  defp await_state(record, state, deadline, last) do
    current = reload(record).state

    cond do
      current == state ->
        {:ok, current}

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, last || current}

      true ->
        # Polling with a pause rather than spinning: a tight reload loop
        # starves the timeline process of the scheduler time it needs to run
        # the action its timer just fired.
        Process.sleep(10)
        await_state(record, state, deadline, current)
    end
  end

  describe "the precise path" do
    test "a deadline 200ms out fires without waiting for a poll" do
      # The timeline's own sweep is an hour away, so anything that fires here
      # was fired by a timer armed from the deadline itself.
      start_timeline([])

      record = candidate(ago(800))
      Timeline.deadline_changed(record, work_for(:waiting))

      assert {:ok, :escalated} = await_state(record, :escalated, 2_000)
    end

    test "a deadline already past fires immediately" do
      start_timeline([])

      record = candidate(ago(5_000))
      Timeline.deadline_changed(record, work_for(:waiting))

      assert {:ok, :escalated} = await_state(record, :escalated, 1_000)
    end

    test "entering a step arms the deadline with no explicit call" do
      # RecordEvent calls Scheduler.notify_state_change/1 after every state
      # change, so creating the record is the only thing this test does. If
      # that call were missing, nothing would arm and the sweep is an hour out.
      start_timeline([])

      record = candidate(ago(800))

      assert {:ok, :escalated} = await_state(record, :escalated, 2_000)
    end

    test "a deadline the timer lands exactly on still fires" do
      # A timer that runs even a fraction of a millisecond early reads its own
      # deadline as not yet passed, because `Work.match` re-checks it in the
      # data layer at fire time. Truncating the delay instead of rounding it up
      # made this fire nothing until the next sweep.
      start_timeline([])

      record = candidate(DateTime.utc_now())

      assert {:ok, :escalated} = await_state(record, :escalated, 3_000)
    end

    test "a record with no deadline written arms nothing" do
      start_timeline([])

      record = candidate(nil)
      Timeline.deadline_changed(record, work_for(:waiting))

      assert {:timeout, :waiting} = await_state(record, :escalated, 300)
    end
  end

  describe "the recovery path" do
    test "the sweep fires a deadline nothing armed" do
      record = candidate(ago(5_000))

      # No deadline_changed/2 call at all: the record was already sitting past
      # its deadline before the timeline started, which is the state a node
      # restart leaves behind.
      start_timeline(look_ahead_ms: 50)

      assert {:ok, :escalated} = await_state(record, :escalated, 2_000)
    end

    test "the sweep arms a deadline inside the horizon rather than firing it" do
      record = candidate(ago(500))

      start_timeline(look_ahead_ms: 50, horizon_ms: 30_000)

      assert {:ok, :escalated} = await_state(record, :escalated, 2_000)
    end

    test "the sweep leaves a deadline beyond the horizon alone" do
      record = candidate(DateTime.utc_now())

      start_timeline(look_ahead_ms: 50, horizon_ms: 100)

      assert {:timeout, :waiting} = await_state(record, :escalated, 400)
    end
  end

  describe "firing re-checks the work" do
    test "a record that left the step fires nothing" do
      start_timeline([])

      record = candidate(ago(800))
      Timeline.deadline_changed(record, work_for(:waiting))

      record
      |> Ash.Changeset.for_update(:resolve, %{})
      |> Ash.update!()

      assert {:timeout, :done} = await_state(record, :escalated, 600)
    end

    test "a deadline pushed out after the timer was armed fires nothing" do
      start_timeline([])

      record = candidate(ago(800))
      Timeline.deadline_changed(record, work_for(:waiting))

      record
      |> Ash.Changeset.for_update(:set_deadline_from, %{deadline_from: DateTime.utc_now()})
      |> Ash.update!()

      assert {:timeout, :waiting} = await_state(record, :escalated, 600)
    end
  end

  describe "cancel/2" do
    test "drops an armed deadline" do
      start_timeline([])

      record = candidate(ago(800))
      Timeline.deadline_changed(record, work_for(:waiting))
      Timeline.cancel(record, [])

      assert {:timeout, :waiting} = await_state(record, :escalated, 600)
    end
  end

  describe "leadership" do
    defmodule NeverLeader do
      @moduledoc false
      @behaviour AshWorkflow.Scheduler.Leader

      @impl AshWorkflow.Scheduler.Leader
      def leader?(_opts), do: false
    end

    defmodule RaisingLeader do
      @moduledoc false
      @behaviour AshWorkflow.Scheduler.Leader

      @impl AshWorkflow.Scheduler.Leader
      def leader?(_opts), do: raise("no peer reachable")
    end

    test "a node that does not lead arms nothing" do
      start_timeline(leader: NeverLeader, look_ahead_ms: 50)

      record = candidate(ago(5_000))
      Timeline.deadline_changed(record, work_for(:waiting))

      assert {:timeout, :waiting} = await_state(record, :escalated, 400)
    end

    test "a leader implementation that raises answers false rather than crashing" do
      refute Leader.leader?({RaisingLeader, []})
    end

    test "normalize accepts a bare module, a tuple, and nothing at all" do
      assert Leader.normalize(nil) == {Leader.Single, []}
      assert Leader.normalize(NeverLeader) == {NeverLeader, []}

      assert Leader.normalize({Leader.Oban, name: MyApp.Oban}) ==
               {Leader.Oban, [name: MyApp.Oban]}
    end
  end

  describe "run_due/2" do
    test "runs a deadline that has passed, with no timeline process at all" do
      record = candidate(ago(5_000))

      assert Precise.run_due(@resource) == 1
      assert reload(record).state == :escalated
    end

    test "runs nothing when no deadline has passed" do
      candidate(DateTime.utc_now())

      assert Precise.run_due(@resource) == 0
    end

    test "returns 0 once the workflow has nothing left to do" do
      candidate(ago(5_000))

      assert Precise.run_due(@resource) == 1
      assert Precise.run_due(@resource) == 0
    end
  end

  describe "the floor it reports" do
    test "Precise is a millisecond, Oban is a minute" do
      assert Scheduler.precision_floor_ms({Precise, []}) == 1
      assert Scheduler.precision_floor_ms({AshWorkflow.Scheduler.Oban, []}) == 60_000
    end
  end

  describe "transform/3" do
    test "adds nothing to the resource, so no triggers exist" do
      assert PreciseTimeoutWorkflow
             |> Extension.get_persisted(:extensions, [])
             |> Enum.member?(AshOban) == false
    end
  end

  defp work_for(step) do
    @resource
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.filter(&(&1.step == step))
  end
end
