with {:module, _} <- Code.ensure_loaded(Clarity.Vertex) do
  defmodule AshWorkflow.Clarity.Vertex.Step do
    @moduledoc """
    One step of an `AshWorkflow` resource, as a vertex in the Clarity graph.

    `AshWorkflow.Clarity.Introspector` adds one for each step, as a child of the
    resource's vertex.
    """

    alias AshWorkflow.Charts.Graph.Node
    alias AshWorkflow.Entities.Step

    @type t() :: %__MODULE__{
            resource: Ash.Resource.t(),
            step: Step.t(),
            kind: Node.kind(),
            initial?: boolean()
          }
    @enforce_keys [:resource, :step, :kind]
    defstruct [:resource, :step, :kind, initial?: false]

    @doc """
    The step's kind as the workflow chart words it: automatic, manual, wait
    state or terminal.
    """
    @spec kind_label(Node.kind()) :: String.t()
    def kind_label(:automatic), do: "automatic"
    def kind_label(:manual), do: "manual"
    def kind_label(:wait_state), do: "wait state"
    def kind_label(:terminal), do: "terminal"

    defimpl Clarity.Vertex do
      alias Clarity.Vertex.Util

      @impl Clarity.Vertex
      def id(%@for{resource: resource, step: step}), do: Util.id(@for, [resource, step.name])

      @impl Clarity.Vertex
      def type_label(_vertex), do: "AshWorkflow Step"

      @impl Clarity.Vertex
      def name(%@for{step: step}), do: Atom.to_string(step.name)
    end

    defimpl Clarity.Vertex.GraphGroupProvider do
      @impl Clarity.Vertex.GraphGroupProvider
      def graph_group(%@for{resource: resource}), do: [inspect(resource), "Workflow"]
    end

    defimpl Clarity.Vertex.GraphShapeProvider do
      @impl Clarity.Vertex.GraphShapeProvider
      def shape(%@for{kind: :terminal}), do: "doublecircle"
      def shape(_vertex), do: "ellipse"
    end

    defimpl Clarity.Vertex.ModuleProvider do
      @impl Clarity.Vertex.ModuleProvider
      def module(%@for{resource: resource}), do: resource
    end

    defimpl Clarity.Vertex.SourceLocationProvider do
      alias Clarity.SourceLocation
      alias Spark.Dsl.Entity

      @impl Clarity.Vertex.SourceLocationProvider
      def source_location(%@for{resource: resource, step: step}) do
        case Entity.anno(step) do
          nil -> SourceLocation.from_module(resource)
          anno -> SourceLocation.from_module_anno(resource, anno)
        end
      end
    end

    defimpl Clarity.Vertex.TooltipProvider do
      @impl Clarity.Vertex.TooltipProvider
      def tooltip(%@for{resource: resource, step: step, kind: kind}) do
        [
          "Workflow step `",
          inspect(step.name),
          "` of `",
          inspect(resource),
          "`\n\n",
          "Kind: ",
          @for.kind_label(kind)
        ]
      end
    end

    # Clarity 0.6.0 has neither protocol. Both arrived with the reworked UI.
    with {:module, _} <- Code.ensure_loaded(Clarity.Vertex.HintProvider) do
      defimpl Clarity.Vertex.HintProvider do
        @impl Clarity.Vertex.HintProvider
        def icon(_vertex), do: :entity

        @impl Clarity.Vertex.HintProvider
        def badges(%@for{kind: kind, initial?: initial?}) do
          if initial?, do: ["initial", @for.kind_label(kind)], else: [@for.kind_label(kind)]
        end

        @impl Clarity.Vertex.HintProvider
        def facts(%@for{resource: resource, step: step}) do
          [
            {"Workflow", inspect(resource)},
            {"Action", step.action && Atom.to_string(step.action)},
            {"Transitions", Enum.map(step.transitions, &Atom.to_string(&1.name))},
            {"Timeouts", Enum.map(step.timeouts, &Atom.to_string(&1.name))}
          ]
          |> Enum.reject(fn {_label, value} -> value in [nil, []] end)
        end
      end
    end

    with {:module, _} <- Code.ensure_loaded(Clarity.Vertex.DetailProvider) do
      defimpl Clarity.Vertex.DetailProvider do
        @impl Clarity.Vertex.DetailProvider
        def detail(%@for{kind: kind, initial?: true}), do: "initial, " <> @for.kind_label(kind)
        def detail(%@for{kind: kind}), do: @for.kind_label(kind)
      end
    end
  end
end
