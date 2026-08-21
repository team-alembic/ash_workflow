defmodule AshWorkflowTest.Postgres.Domain do
  @moduledoc "Domain for the Postgres-backed workflow resources."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshWorkflowTest.Postgres.ApprovalWorkflow
  end
end
