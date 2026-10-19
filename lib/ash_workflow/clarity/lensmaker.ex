with {:module, _} <- Code.ensure_loaded(Clarity.Perspective.Lensmaker),
     {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Ash.Resource) do
  defmodule AshWorkflow.Clarity.Lensmaker do
    @moduledoc """
    Adds a Workflows lens to Clarity: the resources that use `AshWorkflow`,
    each with its steps, and the applications and domains that lead to them.
    """

    @behaviour Clarity.Perspective.Lensmaker

    import Phoenix.Component

    alias AshWorkflow.Clarity.Content
    alias AshWorkflow.Clarity.Vertex.Step
    alias Clarity.Graph
    alias Clarity.Perspective.Lens
    alias Clarity.Vertex

    @contents [
      Content.WorkflowOverview,
      Content.WorkflowDiagram,
      Content.WorkflowTiming,
      Content.StepOverview,
      Content.StepDiagram,
      Content.StepTimeline,
      Clarity.Content.Ash.ApplicationOverview,
      Clarity.Content.Ash.DomainOverview
    ]

    @impl Clarity.Perspective.Lensmaker
    def make_lens do
      # `struct/2` drops `contents` on Clarity releases whose lens has no such
      # field, which then show every tab.
      struct(Lens,
        id: "workflows",
        name: "Workflows",
        description: "Shows AshWorkflow resources, their steps and the moves between them",
        icon: &icon/0,
        filter: &filter/1,
        show_vertex_types: &show_vertex_types/1,
        contents: @contents
      )
    end

    defp icon do
      assigns = %{}

      ~H"""
      <svg
        class="size-full"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <rect x="3" y="3" width="6" height="6" rx="1" />
        <rect x="15" y="15" width="6" height="6" rx="1" />
        <circle cx="18" cy="6" r="3" />
        <path d="M9 6h6" />
        <path d="M18 9v6" />
      </svg>
      """
    end

    @spec filter(Graph.t()) :: Graph.query()
    defp filter(graph) do
      workflows =
        graph
        |> Graph.vertices({:==, :vertex_type, Vertex.Ash.Resource})
        |> Enum.filter(&AshWorkflow.Info.workflow?(&1.resource))

      ancestor_ids =
        Enum.flat_map(workflows, fn vertex ->
          case Graph.breadcrumbs(graph, vertex) do
            false -> [Vertex.id(vertex)]
            path -> Enum.map(path, &Vertex.id/1)
          end
        end)

      {:or, {:in, :vertex_id, Enum.uniq(ancestor_ids)}, {:==, :vertex_type, Step}}
    end

    @spec show_vertex_types([module()]) :: [module()]
    defp show_vertex_types(available_types) do
      shown = [Vertex.Application, Vertex.Ash.Domain, Vertex.Ash.Resource, Step]
      Enum.filter(available_types, &(&1 in shown))
    end
  end
end
