defmodule AshWorkflow.Scheduler.Leader.Single do
  @moduledoc """
  Always the leader. The default for `AshWorkflow.Scheduler.Precise`.

  Correct whenever one node arms deadlines: a single-node deployment, a test, a
  demo. On two nodes every deadline fires on both, so `Precise` warns at boot
  when it finds this implementation and more than one connected node.

  Use `AshWorkflow.Scheduler.Leader.Oban` across a cluster.
  """
  @behaviour AshWorkflow.Scheduler.Leader

  @impl AshWorkflow.Scheduler.Leader
  def leader?(_opts), do: true
end
