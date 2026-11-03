with {:module, _} <- Code.ensure_loaded(Clarity.Content) do
  defmodule AshWorkflow.Clarity.Content.StepOverview do
    @moduledoc """
    Clarity tab that describes one workflow step: what runs on entry, who may
    move the record on, the ways in and out, and the timers that fire while a
    record waits there.
    """

    @behaviour Clarity.Content

    import AshWorkflow.Clarity.Markdown

    alias AshWorkflow.Charts.Format
    alias AshWorkflow.Charts.Graph
    alias AshWorkflow.Clarity.Timeline
    alias AshWorkflow.Clarity.Vertex.Step
    alias AshWorkflow.Entities.Transition

    @impl Clarity.Content
    def name, do: "Step Overview"

    @impl Clarity.Content
    def description, do: "What this workflow step runs, and the moves into and out of it"

    @impl Clarity.Content
    def sort_priority, do: -100

    @impl Clarity.Content
    def applies?(%Step{}, _lens), do: true
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Step{} = vertex, _lens) do
      {:markdown, fn _props -> markdown(vertex) end}
    end

    defp markdown(%Step{resource: resource, step: step} = vertex) do
      graph = Graph.build(resource)

      [
        "# ",
        Atom.to_string(step.name),
        "\n\n",
        "**Kind:** ",
        Step.kind_label(vertex.kind),
        if(vertex.initial?, do: " · **initial step**", else: ""),
        "\n\n",
        properties(vertex),
        timing_section(vertex),
        transitions_section(vertex),
        edges_section(
          "Ways out",
          resource,
          Enum.filter(graph.edges, &(&1.from == step.name)),
          :to
        ),
        edges_section(
          "Ways in",
          resource,
          Enum.filter(graph.edges, &(&1.to == step.name)),
          :from
        ),
        timers_section(vertex, graph)
      ]
    end

    defp properties(%Step{resource: resource, step: step}) do
      table(
        ["Property", "Value"],
        [
          ["Workflow", resource_link(resource)],
          ["Runs on entry", action_link(resource, step.action)],
          ["On error", if(step.on_error, do: step_link(resource, step.on_error), else: "—")],
          ["Retry", cell(Format.retry(step.retry))],
          ["Policy", cell(Format.policy(step.policy))]
        ]
      )
    end

    defp timing_section(%Step{resource: resource, step: step}) do
      timeline = Timeline.step(resource, step.name)

      rows =
        for moment <- timeline.moments, event <- moment.events do
          [moment.label, cell(event.text)]
        end

      lag =
        if timeline.lag,
          do: " The scheduler runs each deadline up to #{timeline.lag} after it falls due.",
          else: ""

      [
        "## Timing\n\n",
        "A record leaves this step ",
        Timeline.leaves_by_text(timeline, step),
        ".",
        lag,
        "\n\n",
        table(["When", "What happens"], rows)
      ]
    end

    defp transitions_section(%Step{step: %{transitions: []}}), do: []

    defp transitions_section(%Step{resource: resource, step: step}) do
      undo? = AshWorkflow.Info.undo(resource) != nil

      rows =
        for transition <- step.transitions do
          [
            action_link(resource, transition.name),
            transition
            |> Transition.all_targets()
            |> Enum.map(&step_link(resource, &1))
            |> Enum.intersperse(", "),
            accepts(transition.accept),
            if(undo? and transition.undoable?, do: "yes", else: "no")
          ]
        end

      [
        "## Transitions callers can run\n\n",
        table(["Transition", "Targets", "Accepts", "Undoable"], rows)
      ]
    end

    defp accepts([]), do: "—"
    defp accepts(fields), do: fields |> Enum.map(&code/1) |> Enum.intersperse(", ")

    defp edges_section(_title, _resource, [], _other_end), do: []

    defp edges_section(title, resource, edges, other_end) do
      heading = if other_end == :to, do: "To", else: "From"

      rows =
        for edge <- edges do
          [
            step_link(resource, Map.fetch!(edge, other_end)),
            edge_kind(edge.kind),
            edge_trigger(edge),
            edge_condition(edge)
          ]
        end

      ["## ", title, "\n\n", table([heading, "Kind", "Trigger", "Condition"], rows)]
    end

    defp timers_section(%Step{resource: resource, step: step}, graph) do
      node = Enum.find(graph.nodes, &(&1.id == step.name))

      rows =
        for note <- node.notes, note.kind in [:timeout, :every] do
          [code(note.name), note.label, action_link(resource, note.action), cell(note.retry)]
        end

      case rows do
        [] ->
          []

        rows ->
          [
            "## Timers that stay in this step\n\n",
            table(["Name", "Fires", "Runs", "Retry"], rows)
          ]
      end
    end
  end
end
