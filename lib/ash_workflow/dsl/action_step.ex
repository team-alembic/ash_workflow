defmodule AshWorkflow.Dsl.ActionStep do
  alias AshWorkflow.Template
  alias AshWorkflow.Dsl.Argument

  defstruct [:name, :action, :resource, :initial]

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: """
      The name of the step
      """
    ],
    action: [
      type: :atom,
      required: true,
      doc: """
      The name of the action to call on the resource.
      """
    ],
    resource: [
      type: {:spark, Ash.Resource},
      required: true,
      doc: """
      The resource to call the action on.
      """
    ],
    initial: [
      type: Template.type(),
      required: false,
      doc: "The record to update."
    ]
  ]

  def __entity__,
    do: %Spark.Dsl.Entity{
      name: :action_step,
      describe: """
      Declares an step in the workflow.
      """,
      examples: [
        """
        step :name, :action, Resource
        """
      ],
      target: __MODULE__,
      args: [:name, :action, :resource],
      schema: @schema,
      entities: [arguments: [Argument.__entity__()]],
      imports: [Template]
    }
end
