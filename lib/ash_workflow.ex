defmodule AshWorkflow do
  @moduledoc """
  `Ash.Workflow` is an extension for Ash that provides a way to define workflows
  by chaining together actions.
  """
  @steps %Spark.Dsl.Entity{
    name: :step,
    describe: """
    Declares an attribute on the resource.
    """,
    examples: [
      """
      attribute :name, :string do
        allow_nil? false
      end
      """
    ],
    target: AshWorkflow.Step,
    args: [:name, :type],
    schema: AshWorkflow.Step.attribute_schema()
  }

  @workflow %Spark.Dsl.Section{
    name: :workflow,
    describe: "Define a workflow by chaining together actions",
    schema: [],
    entities: [
      @steps
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@workflow],
    transformers: [AshWorkflow.Transformer]
end
