defmodule AshWorkflow.Charts.Layered.Rank do
  @moduledoc false
  # Longest-path ranking. A node with no incoming edge gets rank 0. Every other
  # node gets the smallest rank that keeps each incoming edge at least two
  # ranks long, so the odd rank between two steps can hold the edge's label.

  @minlen 2

  def run(nodes, edges) do
    incoming = Enum.group_by(edges, & &1.to, & &1.from)

    nodes
    |> topological(edges)
    |> Enum.reduce(%{}, fn id, ranks ->
      rank =
        incoming
        |> Map.get(id, [])
        |> Enum.map(fn from -> Map.fetch!(ranks, from) + @minlen end)
        |> Enum.max(fn -> 0 end)

      Map.put(ranks, id, rank)
    end)
  end

  # Kahn's algorithm. It takes the first ready node in input order, so the
  # result does not depend on map order.
  defp topological(nodes, edges) do
    ids = Enum.map(nodes, & &1.id)

    indegree =
      Enum.reduce(edges, Map.new(ids, &{&1, 0}), fn edge, indegree ->
        Map.update!(indegree, edge.to, fn n -> n + 1 end)
      end)

    out = Enum.group_by(edges, & &1.from, & &1.to)
    take(ids, indegree, out, [])
  end

  defp take(ids, indegree, out, acc) do
    case Enum.find(ids, fn id -> Map.fetch!(indegree, id) == 0 end) do
      nil ->
        Enum.reverse(acc)

      id ->
        indegree =
          out
          |> Map.get(id, [])
          |> Enum.reduce(indegree, fn to, indegree -> Map.update!(indegree, to, &(&1 - 1)) end)

        take(List.delete(ids, id), indegree, out, [id | acc])
    end
  end
end
