defmodule AshWorkflowDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshWorkflowDemoWeb.Telemetry,
      AshWorkflowDemo.Repo,
      {DNSCluster, query: Application.get_env(:ash_workflow_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AshWorkflowDemo.PubSub},
      AshWorkflowDemo.TunnelUrl,
      {Oban, Application.fetch_env!(:ash_workflow_demo, Oban)},
      AshWorkflowDemo.DemoScheduler,
      # Start to serve requests, typically the last entry
      AshWorkflowDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshWorkflowDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AshWorkflowDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
