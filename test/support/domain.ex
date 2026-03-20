defmodule AshWorkflowTest.Domain do
  use Ash.Domain

  resources do
    resource AshWorkflowTest.Workflow
    resource AshWorkflowTest.LinearWorkflow
    resource AshWorkflowTest.ApprovalWorkflow
    resource AshWorkflowTest.TimeoutWorkflow
    resource AshWorkflowTest.PolicyWorkflow
    resource AshWorkflowTest.FullPipeline
    resource AshWorkflowTest.LoopbackWorkflow
    resource AshWorkflowTest.CustomActionWorkflow
  end
end
