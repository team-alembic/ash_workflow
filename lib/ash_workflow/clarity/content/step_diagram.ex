with {:module, _} <- Code.ensure_loaded(Clarity.Content) do
  defmodule AshWorkflow.Clarity.Content.StepDiagram do
    @moduledoc """
    Clarity tab that draws one workflow step with every step a single move
    away from it.
    """

    @behaviour Clarity.Content

    alias AshWorkflow.Clarity.Diagram
    alias AshWorkflow.Clarity.Vertex.Step

    @impl Clarity.Content
    def name, do: "Step Diagram"

    @impl Clarity.Content
    def description, do: "The moves into and out of this step"

    @impl Clarity.Content
    def sort_priority, do: -90

    @impl Clarity.Content
    def applies?(%Step{}, _lens), do: true
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Step{resource: resource, step: step}, _lens) do
      {:mermaid,
       fn props -> Diagram.neighbourhood(resource, step.name, Map.get(props, :theme, :light)) end}
    end
  end
end
