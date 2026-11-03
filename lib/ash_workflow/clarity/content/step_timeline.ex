with {:module, _} <- Code.ensure_loaded(Clarity.Content) do
  defmodule AshWorkflow.Clarity.Content.StepTimeline do
    @moduledoc """
    Clarity tab that lays out what happens to a record in one workflow step,
    in order of how long after entering the step it happens.
    """

    @behaviour Clarity.Content

    alias AshWorkflow.Clarity.Diagram
    alias AshWorkflow.Clarity.Vertex.Step

    @impl Clarity.Content
    def name, do: "Step Timeline"

    @impl Clarity.Content
    def description, do: "What runs, opens and fires in this step, and when"

    @impl Clarity.Content
    def sort_priority, do: -85

    @impl Clarity.Content
    def applies?(%Step{}, _lens), do: true
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Step{resource: resource, step: step}, _lens) do
      {:mermaid, fn _props -> Diagram.step_timeline(resource, step.name) end}
    end
  end
end
