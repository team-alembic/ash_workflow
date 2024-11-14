defmodule AshWorkflow.Info do
  use Spark.InfoGenerator, extension: AshWorkflow, sections: [:workflow]
  alias Spark.Dsl.Extension

  def steps(dsl) do
    dsl
    |> workflow()
  end

  def get_ordered_steps(dsl) do
    Extension.get_opt(dsl, [:ash_workflow], :ordered_steps, [])
  end

  def get_previous_step(dsl, step) do
    get_ordered_steps(dsl)
    |> Enum.reduce_while(
      nil,
      fn
        ^step, prev_step ->
          {:halt, prev_step}

        curr_step, _ ->
          {:cont, curr_step}
      end
    )
  end

  def get_next_step(dsl, step) do
    get_ordered_steps(dsl)
    |> Enum.reverse()
    |> Enum.reduce_while(
      nil,
      fn
        ^step, next_step ->
          {:halt, next_step}

        curr_step, _ ->
          {:cont, curr_step}
      end
    )
  end
end
