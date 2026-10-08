with {:module, _} <- Code.ensure_loaded(Clarity.Content),
     {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Ash.Resource) do
  defmodule AshWorkflow.Clarity.Content.WorkflowTiming do
    @moduledoc """
    Clarity tab that lists, step by step, how long a record of a workflow
    resource can stay in each step and what happens to it at each moment while
    it is there.
    """

    @behaviour Clarity.Content

    import AshWorkflow.Clarity.Markdown

    alias AshWorkflow.Clarity.Timeline
    alias AshWorkflow.Clarity.Vertex.Step
    alias AshWorkflow.Info
    alias Clarity.Vertex.Ash.Resource

    @impl Clarity.Content
    def name, do: "Workflow Timing"

    @impl Clarity.Content
    def description,
      do: "How long a record can stay in each step, and what happens while it waits"

    @impl Clarity.Content
    def sort_priority, do: -85

    @impl Clarity.Content
    def applies?(%Resource{resource: resource}, _lens), do: Info.workflow?(resource)
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Resource{resource: resource}, _lens) do
      {:markdown, fn _props -> markdown(resource) end}
    end

    defp markdown(resource) do
      steps = Enum.reject(Info.steps(resource), &AshWorkflow.Entities.Step.terminal?/1)
      timelines = Enum.map(steps, &{&1, Timeline.step(resource, &1.name)})

      [
        "# ",
        inspect(resource),
        " timing\n\n",
        "Every time below is measured from the moment a record enters the step, unless it names a field on the record.",
        lag_note(timelines),
        "\n\n",
        summary(resource, timelines),
        Enum.map(timelines, &step_section(resource, &1))
      ]
    end

    defp lag_note([{_step, %{lag: lag}} | _]) when not is_nil(lag),
      do: " The scheduler runs each deadline up to #{lag} after it falls due."

    defp lag_note(_timelines), do: ""

    defp summary(resource, timelines) do
      kinds = Map.new(AshWorkflow.Charts.graph(resource, notes: false).nodes, &{&1.id, &1.kind})

      rows =
        for {step, timeline} <- timelines do
          [
            step_link(resource, step.name),
            kinds |> Map.fetch!(step.name) |> Step.kind_label(),
            cell(Timeline.leaves_by_text(timeline, step))
          ]
        end

      ["## Time in each step\n\n", table(["Step", "Kind", "A record leaves"], rows)]
    end

    defp step_section(resource, {step, timeline}) do
      rows =
        for moment <- timeline.moments, event <- moment.events do
          [moment.label, cell(event.text)]
        end

      [
        "## ",
        step_link(resource, step.name),
        "\n\n",
        "A record leaves ",
        Timeline.leaves_by_text(timeline, step),
        ".\n\n",
        table(["When", "What happens"], rows)
      ]
    end
  end
end
