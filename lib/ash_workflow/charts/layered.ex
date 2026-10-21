defmodule AshWorkflow.Charts.Layered do
  @moduledoc false
  # Spike: a layered (Sugiyama) layout for small directed graphs. No Ash
  # dependency, so it can move to its own package.

  defmodule Node do
    @moduledoc false
    defstruct [:id, width: 0, height: 0]
    @type t :: %__MODULE__{id: term(), width: number(), height: number()}
  end

  defmodule Edge do
    @moduledoc false
    defstruct [:id, :from, :to, label_width: 0, label_height: 0, companion: nil]

    @type t :: %__MODULE__{
            id: term(),
            from: term(),
            to: term(),
            label_width: number(),
            label_height: number()
          }
  end

  defmodule Result do
    @moduledoc false
    defstruct width: 0,
              height: 0,
              crossings: 0,
              nodes: %{},
              edges: %{},
              reversed: MapSet.new(),
              direction: :down,
              routing: :polyline,
              loops: MapSet.new()

    @type t :: %__MODULE__{}
  end

  alias __MODULE__.{Acyclic, NetworkSimplex, Normalize, Order, Position, Rank, Route}

  @defaults [
    rank_sep: 48,
    node_sep: 32,
    edge_sep: 12,
    margin: 16,
    sweeps: 8,
    passes: 8,
    ranker: :network_simplex,
    acyclic: :dfs,
    heuristic: :mean_index,
    tie: :current,
    placement: :network_simplex
  ]

  @spec layout([Node.t()], [Edge.t()], keyword()) :: Result.t()
  def layout(nodes, edges, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    {companions, edges} = Enum.split_with(edges, &(&1.companion != nil))
    {loops, edges} = Enum.split_with(edges, &(&1.from == &1.to))
    {dag, reversed} = Acyclic.run(nodes, edges, opts[:acyclic])

    ranks =
      case opts[:ranker] do
        :network_simplex ->
          NetworkSimplex.run(Enum.map(nodes, & &1.id), Enum.map(dag, &{&1.from, &1.to, 2, 1}))

        _longest_path ->
          Rank.run(nodes, dag)
      end

    graph = Normalize.run(nodes, dag, ranks)
    {layers, crossings} = Order.run(graph, opts[:sweeps], opts)
    coords = Position.run(graph, layers, opts)

    %{
      (graph
       |> Route.run(coords, reversed, loops, opts)
       |> Route.companions(companions, opts[:routing]))
      | crossings: crossings,
        direction: Keyword.get(opts, :direction, :down),
        routing: Keyword.get(opts, :routing, :polyline)
    }
  end
end
