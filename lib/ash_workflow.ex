defmodule AshWorkflow do
  @moduledoc """
  `Ash.Workflow` is an extension for Ash that provides a way to define workflows
  by chaining together actions.
  """
  alias AshWorkflow.Entities

  @argument Entities.Argument.__entity__()

  @action_step %Spark.Dsl.Entity{
    name: :action_step,
    describe: """
    Declares an step in the workflow.
    """,
    examples: [
      """
      step :name, :action, Resource
      """
    ],
    target: Entities.Step,
    args: [:name, :action, :resource],
    schema: Entities.Step.attribute_schema(),
    entities: [arguments: [@argument]]
  }

  @workflow_step %Spark.Dsl.Entity{
    name: :workflow_step,
    describe: """
    Declares an sub workflow in the workflow.
    """,
    examples: [
      """
      workflow :name, Workflow
      """
    ],
    target: Entities.Workflow,
    args: [:name, :workflow],
    schema: Entities.Workflow.attribute_schema(),
    entities: [arguments: [@argument]]
  }

  # TODO:
  # make results available as inputs to other steps
  # conditinals
  # reactor_step (possible just calling a generic action)

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by chaining together actions",
    schema: [],
    entities: [
      @action_step,
      @workflow_step
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    transformers: [AshWorkflow.Transformer],
    add_extensions: [AshStateMachine]
end
