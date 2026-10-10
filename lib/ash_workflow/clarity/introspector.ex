with {:module, _} <- Code.ensure_loaded(Clarity.Introspector),
     {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Ash.Resource) do
  defmodule AshWorkflow.Clarity.Introspector do
    @moduledoc """
    Adds a `AshWorkflow.Clarity.Vertex.Step` for each step of every resource
    that uses `AshWorkflow`, linked from the resource by a `:workflow_step` edge.
    """

    @behaviour Clarity.Introspector

    alias AshWorkflow.Clarity.Vertex.Step
    alias Clarity.Vertex.Ash.Resource

    @impl Clarity.Introspector
    def source_vertex_types, do: [Resource]

    @impl Clarity.Introspector
    def introspect_vertex(%Resource{resource: resource} = resource_vertex, _graph) do
      if AshWorkflow.Info.workflow?(resource) do
        {:ok, step_entries(resource_vertex, resource)}
      else
        {:ok, []}
      end
    end

    defp step_entries(resource_vertex, resource) do
      nodes = Map.new(AshWorkflow.Charts.graph(resource, notes: false).nodes, &{&1.id, &1})

      Enum.flat_map(AshWorkflow.Info.steps(resource), fn step ->
        node = Map.fetch!(nodes, step.name)

        step_vertex = %Step{
          resource: resource,
          step: step,
          kind: node.kind,
          initial?: node.initial?
        }

        [{:vertex, step_vertex}, {:edge, resource_vertex, step_vertex, :workflow_step}]
      end)
    end
  end
end
