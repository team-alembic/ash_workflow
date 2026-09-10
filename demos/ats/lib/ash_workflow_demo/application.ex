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
      # Start to serve requests, typically the last entry
      AshWorkflowDemoWeb.Endpoint
    ]

    children = children ++ timeline()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AshWorkflowDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Holds one timer per pending deadline. Both of the workflow's deadlines are
  # shorter than a minute, so there is no queue and no cron here: the scheduler
  # is told each deadline as a candidate reaches it, and the sweep only has to
  # catch deadlines this node missed while restarting.
  #
  # Tests do not run it. It fires work from its own process, which holds no
  # `Ecto.Adapters.SQL.Sandbox` connection, so it could neither see a test's
  # data nor be waited on. `AshWorkflow.Scheduler.Precise.run_due/2` runs the
  # same work on the test's own connection instead — see
  # `AshWorkflowDemo.DataCase.run_workflow_triggers/2`.
  defp timeline do
    if Application.get_env(:ash_workflow_demo, :start_scheduler?, true) do
      [
        {AshWorkflow.Scheduler.Precise.Timeline,
         resources: [AshWorkflowDemo.ATS.Candidate], look_ahead_ms: 1_000}
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AshWorkflowDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
