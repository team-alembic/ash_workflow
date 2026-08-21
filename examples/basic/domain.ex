defmodule BasicWorkflow.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource BasicWorkflow.DocumentApproval
  end
end
