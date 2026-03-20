defmodule BasicWorkflow.Domain do
  use Ash.Domain

  resources do
    resource BasicWorkflow.DocumentApproval
  end
end
