defmodule AshWorkflow.Template do
  alias AshWorkflow.Template.Result

  @spec result(atom, [any]) :: Template.Result.t()
  def result(step_name, sub_path \\ [])

  def result(step_name, sub_path),
    do: %Result{name: step_name, sub_path: List.wrap(sub_path)}

  @spec type :: Spark.Options.type()
  def type, do: {:or, [{:struct, Result}]}
end
