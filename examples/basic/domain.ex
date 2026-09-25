defmodule BasicWorkflow.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource BasicWorkflow.DocumentApproval
    resource BasicWorkflow.Incident
    resource BasicWorkflow.IncidentTransition
    resource BasicWorkflow.Subscription
    resource BasicWorkflow.ScheduledPost
  end
end
