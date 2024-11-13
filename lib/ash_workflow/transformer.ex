defmodule AshWorkflow.Transformer do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    dsl =
      if(Ash.Resource.Info.short_name(dsl) == :workflow) do
        dsl =
          dsl
          |> add_actions()

        dsl
      else
        dsl
      end

    {:ok, dsl}
  end

  defp add_actions(dsl) do
    dsl
    |> add_start_action()
  end

  defp add_start_action(dsl) do
    action =
      Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :create, name: :start)

    code_interface =
      Transformer.build_entity!(Ash.Resource.Dsl, [:code_interface], :define, name: :start)

    dsl
    |> Transformer.add_entity([:actions], action)
    |> Transformer.add_entity([:code_interface], code_interface)
  end

  @impl true
  def before?(_) do
    true
  end
end
