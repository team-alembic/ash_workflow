defmodule AshWorkflow.Transformer do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    dsl =
      dsl
      |> add_states()
      |> add_attributes()
      |> add_actions()
      |> add_calculations()

    {:ok, dsl}
  end

  defp add_states(dsl) do
    [initial_state | extra_states] =
      states =
      dsl
      |> AshWorkflow.Info.steps()
      |> Enum.map(& &1.name)

    all_states = states ++ [:done]

    List.delete_at(all_states, -1)
    |> Enum.zip(List.delete_at(all_states, 0))
    |> Enum.reduce([], fn {from, to}, transistions ->
      [
        Transformer.build_entity!(AshStateMachine, [:state_machine, :transitions], :transition,
          action: :next,
          from: from,
          to: to
        )
        | transistions
      ]
    end)
    |> Enum.reduce(dsl, &Transformer.add_entity(&2, [:state_machine, :transitions], &1))
    |> Transformer.set_option([:state_machine], :state_attribute, :current_step)
    |> Transformer.set_option([:state_machine], :initial_states, [initial_state])
    |> Transformer.set_option([:state_machine], :extra_states, extra_states ++ [:done])
    |> Transformer.set_option([:state_machine], :default_initial_state, initial_state)
    |> Transformer.set_option([:ash_workflow], :ordered_steps, all_states)
  end

  defp add_attributes(dsl) do
    dsl
    |> add_results()
  end

  defp add_results(dsl) do
    results =
      Transformer.build_entity!(Ash.Resource.Dsl, [:attributes], :attribute,
        type: {:array, :map},
        name: :results
      )

    dsl
    |> Transformer.add_entity([:attributes], results)
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
        require_atomic?: false,
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

  defp debug_workflow(dsl, statement) do
    if(Ash.Resource.Info.short_name(dsl) == :workflow) do
      dbg(statement)
    end
  end

  @impl true
  def before?(_) do
    true
  end
end
