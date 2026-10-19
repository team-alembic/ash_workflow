with {:module, _} <- Code.ensure_loaded(Clarity.Content),
     {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Ash.Resource) do
  defmodule AshWorkflow.Clarity.Content.WorkflowDiagram do
    @moduledoc """
    Clarity tab that draws a workflow resource's steps and moves as a state
    diagram, with each step coloured by its kind.
    """

    @behaviour Clarity.Content

    alias AshWorkflow.Clarity.Diagram
    alias Clarity.Vertex.Ash.Resource

    @impl Clarity.Content
    def name, do: "Workflow Diagram"

    @impl Clarity.Content
    def description, do: "The workflow's steps and the moves between them"

    @impl Clarity.Content
    def sort_priority, do: -90

    @impl Clarity.Content
    def applies?(%Resource{resource: resource}, _lens), do: AshWorkflow.Info.workflow?(resource)
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Resource{resource: resource}, _lens) do
      {:mermaid, fn props -> Diagram.workflow(resource, Map.get(props, :theme, :light)) end}
    end
  end
end
