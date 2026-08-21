defmodule AshWorkflowTest.DslIntrospection do
  @moduledoc """
  Walks the AshWorkflow DSL so tests can assert against the real set of
  options rather than a hand-maintained list.
  """

  @doc "Every option name in the workflow DSL, paired with the path to its entity."
  def dsl_options do
    Enum.flat_map(AshWorkflow.sections(), fn section ->
      section_options = Enum.map(Keyword.keys(section.schema), &{[section.name], &1})

      section_options ++ Enum.flat_map(section.entities, &entity_options(&1, [section.name]))
    end)
  end

  defp entity_options(entity, path) do
    path = path ++ [entity.name]

    options =
      entity.schema
      |> Keyword.keys()
      # Positional args are given as the entity's arguments, not as named
      # options, so they are documented by the entity itself.
      |> Enum.reject(&(&1 in entity.args))
      |> Enum.map(&{path, &1})

    nested =
      Enum.flat_map(entity.entities, fn {_key, entities} ->
        Enum.flat_map(entities, &entity_options(&1, path))
      end)

    options ++ nested
  end
end
