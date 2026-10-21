defmodule AshWorkflow.Charts.Layered.Acyclic do
  @moduledoc false
  # Reverses each edge that a depth-first search, in input order, finds going
  # back to a node on its stack. Undo edges and retry loops are such edges.
  # Returns the edges of the acyclic graph and the ids of the reversed edges.

  def run(nodes, edges) do
    out = Enum.group_by(edges, & &1.from)

    {_visited, reversed} =
      Enum.reduce(nodes, {MapSet.new(), MapSet.new()}, fn node, acc ->
        visit(node.id, out, MapSet.new(), acc)
      end)

    dag =
      Enum.map(edges, fn edge ->
        if MapSet.member?(reversed, edge.id),
          do: %{edge | from: edge.to, to: edge.from},
          else: edge
      end)

    {dag, reversed}
  end

  defp visit(id, out, stack, {visited, reversed} = acc) do
    if MapSet.member?(visited, id) do
      acc
    else
      stack = MapSet.put(stack, id)

      out
      |> Map.get(id, [])
      |> Enum.reduce({MapSet.put(visited, id), reversed}, fn edge, {visited, reversed} ->
        if MapSet.member?(stack, edge.to),
          do: {visited, MapSet.put(reversed, edge.id)},
          else: visit(edge.to, out, stack, {visited, reversed})
      end)
    end
  end
end
