defmodule AshWorkflow do
  @moduledoc """
  `Ash.Workflow` is an extension for Ash that provides a way to define workflows
  by chaining together actions.
  """
  alias AshWorkflow.Entities

  @step %Spark.Dsl.Entity{
    name: :step,
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
    schema: Entities.Step.attribute_schema()
  }

  @sub_workflow %Spark.Dsl.Entity{
    name: :workflow,
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
    schema: Entities.Workflow.attribute_schema()
  }

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by chaining together actions",
    schema: [],
    entities: [
      @step,
      @sub_workflow
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    transformers: [AshWorkflow.Transformer]
end
