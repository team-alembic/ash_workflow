defmodule AshWorkflowTest.Domain do
  @moduledoc false
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
    resource AshWorkflowTest.ConditionalWorkflow
    resource AshWorkflowTest.SharedTransitionWorkflow
    resource AshWorkflowTest.SharedConditionalWorkflow
    resource AshWorkflowTest.AcceptWorkflow
    resource AshWorkflowTest.InitialFlagWorkflow
    resource AshWorkflowTest.RepeatingTimeoutWorkflow
  end
end
