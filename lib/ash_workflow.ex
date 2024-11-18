defmodule AshWorkflow do
  @moduledoc """
  `Ash.Workflow` is an extension for Ash that provides a way to define workflows
  by chaining together actions.
  """
  alias AshWorkflow.Dsl

  # TODO:
  # make results available as inputs to other steps
  # conditinals
  # reactor_step (possible just calling a generic action)

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by chaining together actions",
    schema: [],
    entities: [
      Dsl.ActionStep.__entity__(),
      Dsl.WorkflowStep.__entity__(),
      Dsl.Switch.__entity__()
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    transformers: [AshWorkflow.Transformer],
    add_extensions: [AshStateMachine]
end
