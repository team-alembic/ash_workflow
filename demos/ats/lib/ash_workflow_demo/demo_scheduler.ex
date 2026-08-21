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

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_schedule(:verifying)
    safe_schedule(:__timeout_trigger_auto_reject)
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
