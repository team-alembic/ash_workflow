defmodule AshWorkflow.Entities.Step do
  defstruct [:name, :action, :resource]

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
    ]
  ]

  def attribute_schema do
    @schema
  end
end
