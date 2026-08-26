defmodule AshWorkflowDemo.DemoScheduler do
  @moduledoc """
  Demo-only GenServer that ticks every 1 second and invokes the AshOban
  scheduler for the automatic :verifying step and the :auto_reject timeout.

  Bypasses the default minute-granularity cron so the 30-second timeout
  and near-instant verify step fire visibly on stage.
  """

  use GenServer

  require Logger

  alias AshWorkflowDemo.ATS.Candidate

  @tick_ms 1_000

  @triggers [
    :__timeout_trigger_submitted_begin_verification,
    :verifying,
    :__timeout_trigger_review_auto_reject
  ]

  @doc """
  The AshOban triggers this scheduler drives every tick.

  `safe_schedule/1` swallows a bad name, so drift here is invisible at runtime.
  `AshWorkflowDemo.DemoSchedulerTest` asserts each one still exists.
  """
  def triggers, do: @triggers

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    Enum.each(@triggers, &safe_schedule/1)
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp safe_schedule(trigger) do
    AshOban.schedule(Candidate, trigger)
  rescue
    e -> Logger.warning("DemoScheduler skip #{inspect(trigger)}: #{inspect(e)}")
  end
end
