defmodule AshWorkflow.Entities.Transition do
  defstruct [:name, :to]

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name of the transition. Becomes an Ash update action."
    ],
    to: [
      type: :atom,
      required: true,
      doc: "The step to transition to."
    ]
  ]

  def attribute_schema, do: @schema
end
