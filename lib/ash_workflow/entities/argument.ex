defmodule AshWorkflow.Entities.Argument do
  alias AshWorkflow.Template

  defstruct [:name, :action, :resource]

  @schema [
    key: [
      type: :atom,
      required: true,
      doc: """
      The name of the step
      """
    ],
    value: [
      type: :any,
      required: true,
      doc: """
      The name of the action to call on the resource.
      """
    ]
  ]

  @entity %Spark.Dsl.Entity{
    name: :argument,
    describe: """
    Declares an argument on a step.
    """,
    examples: [
      """
      argument :key, result(:step_name)

      argument :key, result(:step_name, :key)
      """
    ],
    imports: [__MODULE__],
    target: __MODULE__,
    args: [:key, :value],
    schema: @schema
  }

  @doc false
  def __entity__, do: @entity

  @spec result(atom, [any]) :: Template.Result.t()
  def result(step_name, sub_path \\ [])

  def result(step_name, sub_path),
    do: %Template.Result{name: step_name, sub_path: List.wrap(sub_path)}
end
