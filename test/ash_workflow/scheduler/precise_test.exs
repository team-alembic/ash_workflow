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
  alias AshWorkflowTest.PreciseRetryWorkflow
  alias AshWorkflowTest.PreciseTimeoutWorkflow
  alias Spark.Dsl.Extension

  @resource PreciseDeadlineWorkflow
  @table_manager Module.concat(PreciseDeadlineWorkflow, Ash.DataLayer.Ets.TableManager)

  setup do
    on_exit(&reset_storage/0)

    :ok
  end

  # `Ash.DataLayer.Ets.stop/1` sends the table's manager
  # `Process.exit(pid, :shutdown)` and returns without waiting, so the manager
  # is still registered when it returns. The next test then inserts into a
  # table whose manager is already dying, the manager takes the table down with
  # the row still in it, and every read for the rest of that test finds
  # nothing. Waiting for the manager to go is what makes each test start
  # against a table nothing is about to kill.
  defp reset_storage do
    Ets.stop(@resource)

    await_stopped(@table_manager)
  end

  defp await_stopped(name, tries \\ 200) do
    cond do
      is_nil(Process.whereis(name)) -> :ok
      tries == 0 -> raise "#{inspect(name)} did not stop"
      true -> Process.sleep(5) && await_stopped(name, tries - 1)
    end
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

  # Reads through `Ash.get/2` rather than `Ash.get!/2` so a read that finds
  # nothing counts as "not the state yet" and the loop keeps going. It still
  # times out when the record never arrives at the state, and `:missing` names
  # that case in the failure message instead of raising from inside a helper.
  # `reset_storage/0` above is what stops the table disappearing under a test;
  # this is what makes the next such fault legible rather than opaque.
  defp current_state(record, resource) do
    case Ash.get(resource, record.id) do
      {:ok, reloaded} -> reloaded.state
      {:error, _not_found} -> :missing
    end
  end

  defp start_timeline(opts) do
    opts = Keyword.merge([resources: [@resource], look_ahead_ms: 60_000], opts)

    start_supervised!({Timeline, opts})
  end

  defp await_state(record, state, timeout_ms, resource \\ @resource) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    await_state(record, state, deadline, nil, resource)
  end

  defp await_state(record, state, deadline, last, resource) do
    current = current_state(record, resource)

    cond do
      current == state ->
        {:ok, current}

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, if(current == :missing, do: last || current, else: current)}

      true ->
        # Polling with a pause rather than spinning: a tight reload loop
        # starves the timeline process of the scheduler time it needs to run
        # the action its timer just fired.
        Process.sleep(10)
        await_state(record, state, deadline, current, resource)
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
    # Each of these creates the record with no deadline, so nothing is armed
    # and the state change below cannot race a timer. Arming afterwards, from a
    # record whose deadline has passed, is what a stale timer amounts to: a
    # deadline the timeline still believes in and the record no longer matches.
    # Creating with a live deadline and then updating raced the timer, and the
    # update lost with `Attempted to update stale record`.
    test "a record that left the step fires nothing" do
      start_timeline([])

      record = candidate(nil)

      resolved =
        record
        |> Ash.Changeset.for_update(:resolve, %{})
        |> Ash.update!()

      Timeline.deadline_changed(%{resolved | deadline_from: ago(5_000)}, work_for(:waiting))

      assert {:timeout, :done} = await_state(record, :escalated, 400)
    end

    test "a deadline pushed out after the timer was armed fires nothing" do
      start_timeline([])

      record = candidate(nil)

      pushed_out =
        record
        |> Ash.Changeset.for_update(:set_deadline_from, %{
          deadline_from: DateTime.add(DateTime.utc_now(), 60, :second)
        })
        |> Ash.update!()

      # The timeline is told a deadline that has passed while the record's own
      # field says a minute from now, so the re-check at fire time rejects it.
      Timeline.deadline_changed(%{pushed_out | deadline_from: ago(5_000)}, work_for(:waiting))

      assert {:timeout, :waiting} = await_state(record, :escalated, 400)
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

  describe "retry" do
    @retry_resource PreciseRetryWorkflow
    @retry_table_manager Module.concat(PreciseRetryWorkflow, Ash.DataLayer.Ets.TableManager)

    setup do
      on_exit(fn ->
        Ets.stop(@retry_resource)
        await_stopped(@retry_table_manager)
      end)

      :ok
    end

    test "a failed attempt re-arms rather than reaching on_error immediately, and on_error runs once the retry also fails" do
      start_timeline(resources: [@retry_resource])

      record =
        @retry_resource |> Ash.Changeset.for_create(:create, %{title: "one"}) |> Ash.create!()

      # The first attempt fires as soon as the record enters :processing, since
      # an automatic step has no deadline to wait for. It fails, and with
      # max_attempts: 2 that is a retry rather than on_error — the record
      # stays in :processing well past the first attempt, since nothing
      # transitions it until the final attempt also fails.
      assert {:timeout, :processing} =
               await_state(record, :failed, 300, @retry_resource)

      # The retry fires roughly `backoff` seconds later. Once it also fails,
      # this was the final attempt, so on_error runs and the record reaches
      # :failed.
      assert {:ok, :failed} = await_state(record, :failed, 2_000, @retry_resource)
    end
  end

  defp work_for(step) do
    @resource
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.filter(&(&1.step == step))
  end
end
