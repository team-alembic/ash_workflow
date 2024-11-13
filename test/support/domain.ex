defmodule AshWorkflowTest.Domain do
  use Ash.Domain

  resources do
    resource AshWorkflowTest.Workflow
    resource AshWorkflowTest.SubWorkflow
    resource AshWorkflowTest.Step1
  end
end
