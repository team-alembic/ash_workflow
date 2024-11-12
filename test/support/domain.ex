defmodule AshWorkflowTest.Domain do
  use Ash.Domain

  resources do
    resource AshWorkflowTest.Workflow
    resource AshWorkflowTest.Step1
  end
end
