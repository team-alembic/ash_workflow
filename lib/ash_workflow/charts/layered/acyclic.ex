defmodule AshWorkflow.Charts.Layered.Acyclic do
  @moduledoc false
  # Reverses each edge that a depth-first search, in input order, finds going
  # back to a node on its stack. Undo edges and retry loops are such edges.
  # Returns the edges of the acyclic graph and the ids of the reversed edges.

  def run(nodes, edges), do: run(nodes, edges, :dfs)

  def run(nodes, edges, :dfs) do
    out = Enum.group_by(edges, & &1.from)

    {_visited, reversed} =
      Enum.reduce(nodes, {MapSet.new(), MapSet.new()}, fn node, acc ->
        visit(node.id, out, MapSet.new(), acc)
      end)

    {flip(edges, reversed), reversed}
  end

  # Eades, Lin and Smyth (1993): move sinks to the right end and sources to
  # the left end; otherwise move the node with the largest outdegree minus
  # indegree to the left end. Edges that point right to left are reversed.
  # Ties go to the node that comes first in the input, so the reversed edges
  # are the ones a reader expects: a retry or an undo, declared later.
  def run(nodes, edges, :greedy) do
    index = nodes |> Enum.map(& &1.id) |> greedy(edges, [], []) |> Enum.with_index() |> Map.new()
    reversed = for e <- edges, index[e.from] > index[e.to], into: MapSet.new(), do: e.id
    {flip(edges, reversed), reversed}
  end

  defp greedy([], _edges, left, right), do: Enum.reverse(left) ++ right

  defp greedy(ids, edges, left, right) do
    live = Enum.filter(edges, &(&1.from in ids and &1.to in ids))
    indegree = fn id -> Enum.count(live, &(&1.to == id)) end
    outdegree = fn id -> Enum.count(live, &(&1.from == id)) end

    cond do
      sink = Enum.find(ids, &(outdegree.(&1) == 0)) ->
        greedy(List.delete(ids, sink), edges, left, [sink | right])

      source = Enum.find(ids, &(indegree.(&1) == 0)) ->
        greedy(List.delete(ids, source), edges, [source | left], right)

      true ->
        best = Enum.max_by(ids, &(outdegree.(&1) - indegree.(&1)))
        greedy(List.delete(ids, best), edges, [best | left], right)
    end
  end

  defp flip(edges, reversed) do
    Enum.map(edges, fn edge ->
      if MapSet.member?(reversed, edge.id), do: %{edge | from: edge.to, to: edge.from}, else: edge
    end)
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
