defmodule AshWorkflow.Transformer do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    dsl =
      dsl
      |> add_attributes()
      |> add_actions()
      |> add_calculations()

    {:ok, dsl}
  end

  defp add_attributes(dsl) do
    dsl
    |> add_current_step_index()
  end

  defp add_current_step_index(dsl) do
    current_step =
      Transformer.build_entity!(Ash.Resource.Dsl, [:attributes], :attribute,
        type: :integer,
        name: :current_step_index,
        allow_nil?: false,
        default: 0
      )

    dsl
    |> Transformer.add_entity([:attributes], current_step)
  end

  defp add_actions(dsl) do
    dsl
    |> add_read_action()
    |> add_start_action()
    |> add_next_action()
  end

  defp add_read_action(dsl) do
    action =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :read,
        name: :read,
        primary?: true
      )

    dsl
    |> Transformer.add_entity([:actions], action)
  end

  defp add_start_action(dsl) do
    action =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :create,
        name: :start,
        primary?: true
      )

    code_interface =
      Transformer.build_entity!(Ash.Resource.Dsl, [:code_interface], :define, name: :start)

    dsl
    |> Transformer.add_entity([:actions], action)
    |> Transformer.add_entity([:code_interface], code_interface)
  end

  defp add_next_action(dsl) do
    params_argument =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :argument,
        name: :params,
        type: :map
      )

    change =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :update], :change,
        change: {AshWorkflow.Changes.ExecuteStep, []}
      )

    action =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :update,
        name: :next,
        primary?: true,
        arguments: [params_argument],
        changes: [change]
      )

    code_interface =
      Transformer.build_entity!(Ash.Resource.Dsl, [:code_interface], :define, name: :next)

    dsl
    |> Transformer.add_entity([:actions], action)
    |> Transformer.add_entity([:code_interface], code_interface)
  end

  defp add_calculations(dsl) do
    calculation =
      Transformer.build_entity!(Ash.Resource.Dsl, [:calculations], :calculate,
        name: :steps,
        calculation: {AshWorkflow.Calculations.Steps, []},
        type: :struct
      )

    dsl
    |> Transformer.add_entity([:calculations], calculation)
  end

  defp debug_workflow(dsl, statment) do
    if(Ash.Resource.Info.short_name(dsl) == :workflow) do
      dbg(statment)
    end
  end

  @impl true
  def before?(_) do
    true
  end
end
