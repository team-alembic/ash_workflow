defmodule AshWorkflowDemo.ATS.Candidate.Notifier do
  @moduledoc """
  Broadcasts candidate changes to two PubSub topics on every create/update.
  """

  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{data: %{id: id}}) do
    Phoenix.PubSub.broadcast(AshWorkflowDemo.PubSub, "candidates:all", {:candidate_changed, id})
    Phoenix.PubSub.broadcast(AshWorkflowDemo.PubSub, "candidates:#{id}", {:candidate_changed, id})
    :ok
  end
end
