defmodule AshWorkflow.Transformers.AddCodeInterface do
  @moduledoc """
  Generates code interface definitions for workflow actions.

  Adds `define` entries for each manual step transition — e.g.,
  `define :approve`, `define :reject`.

  These generate convenience functions on the resource module so callers can use
  `CandidatePipeline.approve(record)` instead of `Ash.update` directly.

  Skips definitions that the user has already declared.
  """
  use Spark.Dsl.Transformer

  alias AshWorkflow.Entities.Step
  alias Spark.Dsl.Transformer

  def transform(dsl) do
    steps = Transformer.get_entities(dsl, [:workflow])
    existing_defines = Transformer.get_entities(dsl, [:code_interface])
    defined_names = MapSet.new(existing_defines, & &1.name)

    transition_names =
      steps
      |> Enum.filter(&Step.manual?/1)
      |> Enum.flat_map(& &1.transitions)
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    dsl =
      Enum.reduce(transition_names, dsl, fn name, dsl ->
        maybe_add_define(dsl, name, defined_names)
      end)

    {:ok, dsl}
  end

  defp maybe_add_define(dsl, name, defined_names) do
    if MapSet.member?(defined_names, name) do
      dsl
    else
      define =
        Transformer.build_entity!(Ash.Resource.Dsl, [:code_interface], :define, name: name)

      Transformer.add_entity(dsl, [:code_interface], define)
    end
  end

  def after?(_), do: true
end
