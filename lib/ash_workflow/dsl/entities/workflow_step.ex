defmodule AshWorkflow.Entities.WorkflowStep do
  defstruct [:name, :workflow]

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
end
