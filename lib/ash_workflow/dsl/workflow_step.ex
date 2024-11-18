defmodule AshWorkflow.Dsl.WorkflowStep do
  defstruct [:name, :workflow]

  alias AshWorkflow.Dsl.Argument

  @schema [
    name: [
      type: :atom,
      required: false,
      doc: """
      The name of the step
      """
    ],
    workflow: [
      type: {:spark, Ash.Resource},
      required: true,
      doc: """
      The resource to call the action on.
      """
    ]
  ]

  def attribute_schema do
    @schema
  end

  def __entity__,
    do: %Spark.Dsl.Entity{
      name: :workflow_step,
      describe: """
      Declares an sub workflow in the workflow.
      """,
      examples: [
        """
        workflow :name, Workflow
        """
      ],
      target: __MODULE__,
      args: [:name, :workflow],
      schema: @schema,
      entities: [arguments: [Argument.__entity__()]]
    }
end
