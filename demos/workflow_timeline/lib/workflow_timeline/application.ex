defmodule WorkflowTimeline.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WorkflowTimelineWeb.Telemetry,
      WorkflowTimeline.Repo,
      {DNSCluster, query: Application.get_env(:workflow_timeline, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WorkflowTimeline.PubSub},
      {Oban, Application.fetch_env!(:workflow_timeline, Oban)},
      WorkflowTimelineWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: WorkflowTimeline.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    WorkflowTimelineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
