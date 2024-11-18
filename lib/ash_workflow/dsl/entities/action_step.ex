defmodule AshWorkflow.Entities.ActionStep do
  alias AshWorkflow.Template

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

  def attribute_schema do
    @schema
  end
end
