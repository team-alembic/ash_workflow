defmodule AshWorkflowTest.NotifyingScheduler do
  @moduledoc """
  A scheduler that sends the calling process `{:state_change_notified, id}`
  each time `AshWorkflow.Scheduler.notify_state_change/1` reaches it.
  """
  use AshWorkflow.Scheduler

  @impl AshWorkflow.Scheduler
  def deadline_changed(record, _works), do: notify(record)

  @impl AshWorkflow.Scheduler
  def cancel(record, _works), do: notify(record)

  defp notify(record) do
    send(self(), {:state_change_notified, record.id})
    :ok
  end
end
