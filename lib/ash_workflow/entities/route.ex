defmodule AshWorkflow.Entities.Route do
  @moduledoc "A conditional target for a transition. Evaluated at runtime using `Ash.Expr.eval/2`."
  defstruct [:to, :when, __spark_metadata__: nil]

  @type t :: %__MODULE__{to: atom(), when: Ash.Expr.t() | nil}

  @schema [
    to: [
      type: :atom,
      required: true,
      doc: "The step to transition to if the condition matches."
    ],
    when: [
      type: :any,
      required: true,
      doc: "An Ash expression evaluated against the record. Use `expr(attribute == value)`."
    ]
  ]

  def attribute_schema, do: @schema
end
