with {:module, _} <- Code.ensure_loaded(Clarity.Content),
     {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Ash.Resource) do
  defmodule AshWorkflow.Clarity.Content.WorkflowOverview do
    @moduledoc """
    Clarity tab that summarises a workflow resource: its steps, every move
    between them, its timers, undo and transition log, and the work it hands
    to the scheduler.
    """

    @behaviour Clarity.Content

    import AshWorkflow.Clarity.Markdown

    alias AshWorkflow.Charts.Format
    alias AshWorkflow.Charts.Graph
    alias AshWorkflow.Clarity.Vertex.Step
    alias AshWorkflow.Info
    alias Clarity.Vertex.Ash.Resource

    @impl Clarity.Content
    def name, do: "Workflow Overview"

    @impl Clarity.Content
    def description, do: "Steps, moves, timers and scheduling of this workflow"

    @impl Clarity.Content
    def sort_priority, do: -95

    @impl Clarity.Content
    def applies?(%Resource{resource: resource}, _lens), do: Info.workflow?(resource)
    def applies?(_vertex, _lens), do: false

    @impl Clarity.Content
    def render_static(%Resource{resource: resource}, _lens) do
      {:markdown, fn _props -> markdown(resource) end}
    end

    defp markdown(resource) do
      graph = Graph.build(resource)

      [
        "# ",
        inspect(resource),
        " workflow\n\n",
        summary(resource, graph),
        steps_section(resource, graph),
        moves_section(resource, graph),
        timers_section(resource, graph),
        scheduling_section(resource)
      ]
    end

    defp summary(resource, graph) do
      counts = Enum.frequencies_by(graph.nodes, & &1.kind)
      initial = Enum.find(graph.nodes, & &1.initial?)

      kinds =
        for kind <- [:automatic, :manual, :wait_state, :terminal], count = counts[kind] do
          "#{count} #{Step.kind_label(kind)}"
        end

      table(
        ["Property", "Value"],
        [
          ["State attribute", code(Info.state_attribute(resource))],
          ["Initial step", if(initial, do: step_link(resource, initial.id), else: "—")],
          ["Steps", "#{length(graph.nodes)} (#{Enum.join(kinds, ", ")})"],
          ["Moves", Integer.to_string(Enum.count(graph.edges, &(&1.kind != :undo)))],
          ["Undo", undo(resource)],
          ["Transition log", transition_log(resource)],
          ["Scheduler", scheduler(resource)]
        ]
      )
    end

    defp undo(resource) do
      case Info.undo(resource) do
        nil ->
          "not enabled"

        undo ->
          [
            Format.undo(undo),
            if(undo.same_actor?, do: ", same actor only", else: ""),
            ", #{length(Info.undoable_edges(resource))} undoable moves"
          ]
      end
    end

    defp transition_log(resource) do
      case Info.transition_log(resource) do
        nil -> "not recorded"
        log -> resource_link(log.resource)
      end
    end

    defp scheduler(resource) do
      {module, _opts} = Info.scheduler(resource)
      code(module)
    end

    defp steps_section(resource, graph) do
      steps = Map.new(Info.steps(resource), &{&1.name, &1})
      exits = Enum.group_by(graph.edges, & &1.from)

      rows =
        for node <- graph.nodes do
          step = Map.fetch!(steps, node.id)

          [
            step_link(resource, node.id),
            [Step.kind_label(node.kind), if(node.initial?, do: " (initial)", else: "")],
            action_link(resource, step.action),
            exits |> Map.get(node.id, []) |> Enum.reject(&(&1.kind == :undo)) |> targets(),
            cell(Format.policy(step.policy))
          ]
        end

      ["## Steps\n\n", table(["Step", "Kind", "Runs", "Leads to", "Policy"], rows)]
    end

    defp targets([]), do: "—"

    defp targets(edges) do
      edges |> Enum.map(& &1.to) |> Enum.uniq() |> Enum.map_join(", ", &"`#{&1}`")
    end

    defp moves_section(resource, graph) do
      rows =
        for edge <- graph.edges do
          [
            step_link(resource, edge.from),
            step_link(resource, edge.to),
            edge_kind(edge.kind),
            edge_trigger(edge),
            edge_condition(edge)
          ]
        end

      ["## Moves\n\n", table(["From", "To", "Kind", "Trigger", "Condition"], rows)]
    end

    defp timers_section(resource, graph) do
      timeouts =
        for edge <- graph.edges, edge.kind == :timeout do
          [
            step_link(resource, edge.from),
            code(edge.name),
            edge.label,
            ["moves to ", code(edge.to)],
            "—"
          ]
        end

      notes =
        for node <- graph.nodes, note <- node.notes, note.kind in [:timeout, :every] do
          [
            step_link(resource, node.id),
            code(note.name),
            note.label,
            ["runs ", action_link(resource, note.action)],
            cell(note.retry)
          ]
        end

      case timeouts ++ notes do
        [] -> []
        rows -> ["## Timers\n\n", table(["Step", "Name", "Fires", "Effect", "Retry"], rows)]
      end
    end

    defp scheduling_section(resource) do
      work =
        for work <- Info.scheduled_work(resource) do
          [
            code(work.name),
            Atom.to_string(work.kind),
            step_link(resource, work.step),
            action_link(resource, work.action),
            cell(Format.retry(work.retry))
          ]
        end

      indexes =
        resource
        |> Info.recommended_indexes()
        |> Enum.map(&["- `[", Enum.map_join(&1, ", ", fn field -> inspect(field) end), "]`\n"])

      [
        if(work == [],
          do: [],
          else: [
            "## Scheduled work\n\n",
            table(["Work", "Kind", "Step", "Action", "Retry"], work)
          ]
        ),
        if(indexes == [], do: [], else: ["## Recommended indexes\n\n", indexes, "\n"])
      ]
    end
  end
end
