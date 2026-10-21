defmodule AshWorkflow.Charts.Layered.NetworkSimplex do
  @moduledoc false
  # Network simplex, after Gansner, Koutsofios, North and Vo (1993), "A
  # Technique for Drawing Directed Graphs", section 2: integer ranks that
  # minimise the sum of weight * (rank(to) - rank(from)), with every edge at
  # least minlen long. The same solver places x on an auxiliary graph
  # (section 4.2), so the input is generic. The graphs are small, so cut
  # values are recomputed from scratch on each iteration.

  @max_iterations 1_000

  def run([], _edges), do: %{}

  def run(ids, edges) do
    edges =
      edges
      |> Enum.with_index()
      |> Enum.map(fn {{from, to, minlen, weight}, i} ->
        %{i: i, from: from, to: to, minlen: minlen, weight: weight}
      end)

    ids
    |> components(edges)
    |> Enum.map(fn component ->
      members = MapSet.new(component)
      solve(component, Enum.filter(edges, &MapSet.member?(members, &1.from)))
    end)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp solve(ids, edges) do
    ranks = longest_path(ids, edges)
    {tree, ranks} = feasible_tree(ids, edges, ranks)
    ranks = improve(tree, edges, ranks, 0)
    low = ranks |> Map.values() |> Enum.min()
    Map.new(ranks, fn {id, rank} -> {id, rank - low} end)
  end

  defp longest_path(ids, edges) do
    incoming = Enum.group_by(edges, & &1.to)

    ids
    |> topological(edges)
    |> Enum.reduce(%{}, fn id, ranks ->
      rank =
        incoming
        |> Map.get(id, [])
        |> Enum.map(fn e -> Map.fetch!(ranks, e.from) + e.minlen end)
        |> Enum.max(fn -> 0 end)

      Map.put(ranks, id, rank)
    end)
  end

  defp topological(ids, edges) do
    indegree =
      Enum.reduce(edges, Map.new(ids, &{&1, 0}), fn e, acc ->
        Map.update!(acc, e.to, &(&1 + 1))
      end)

    out = Enum.group_by(edges, & &1.from, & &1.to)
    take(ids, indegree, out, [])
  end

  defp take(ids, indegree, out, acc) do
    case Enum.find(ids, &(Map.fetch!(indegree, &1) == 0)) do
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

  # Grow a tree of tight edges (slack 0) from the first node. When it stops
  # short, shift the tree so the incident edge with the least slack becomes
  # tight, and grow again.
  defp feasible_tree([first | _] = ids, edges, ranks),
    do: grow(MapSet.new([first]), MapSet.new(), length(ids), edges, ranks)

  defp grow(nodes, tree, size, edges, ranks) do
    {nodes, tree} = tight_tree(nodes, tree, edges, ranks)

    if MapSet.size(nodes) == size do
      {tree, ranks}
    else
      edge =
        edges
        |> Enum.filter(&(MapSet.member?(nodes, &1.from) != MapSet.member?(nodes, &1.to)))
        |> Enum.min_by(&slack(&1, ranks))

      delta =
        if MapSet.member?(nodes, edge.from), do: slack(edge, ranks), else: -slack(edge, ranks)

      grow(nodes, tree, size, edges, shift(ranks, nodes, delta))
    end
  end

  defp tight_tree(nodes, tree, edges, ranks) do
    found =
      Enum.find(edges, fn e ->
        MapSet.member?(nodes, e.from) != MapSet.member?(nodes, e.to) and slack(e, ranks) == 0
      end)

    case found do
      nil ->
        {nodes, tree}

      e ->
        tight_tree(
          nodes |> MapSet.put(e.from) |> MapSet.put(e.to),
          MapSet.put(tree, e.i),
          edges,
          ranks
        )
    end
  end

  # Swap a tree edge with a negative cut value for the non-tree edge with the
  # least slack that crosses the same cut from the head side to the tail side.
  defp improve(_tree, _edges, ranks, n) when n >= @max_iterations, do: ranks

  defp improve(tree, edges, ranks, n) do
    case leave_edge(tree, edges) do
      nil ->
        ranks

      {leave, head_side} ->
        enter =
          edges
          |> Enum.reject(&MapSet.member?(tree, &1.i))
          |> Enum.filter(
            &(MapSet.member?(head_side, &1.from) and not MapSet.member?(head_side, &1.to))
          )
          |> Enum.min_by(&slack(&1, ranks))

        ranks = shift(ranks, head_side, slack(enter, ranks))
        improve(tree |> MapSet.delete(leave.i) |> MapSet.put(enter.i), edges, ranks, n + 1)
    end
  end

  # Cut value: the weight of edges from the tail side to the head side, minus
  # the weight of edges from the head side to the tail side.
  defp leave_edge(tree, edges) do
    tree_edges = Enum.filter(edges, &MapSet.member?(tree, &1.i))

    Enum.find_value(tree_edges, fn t ->
      head_side = reach(t.to, List.delete(tree_edges, t))

      cut =
        Enum.reduce(edges, 0, fn e, acc ->
          case {MapSet.member?(head_side, e.from), MapSet.member?(head_side, e.to)} do
            {false, true} -> acc + e.weight
            {true, false} -> acc - e.weight
            _ -> acc
          end
        end)

      if cut < 0, do: {t, head_side}
    end)
  end

  defp reach(start, tree_edges) do
    adjacency =
      Enum.reduce(tree_edges, %{}, fn e, acc ->
        acc
        |> Map.update(e.from, [e.to], &[e.to | &1])
        |> Map.update(e.to, [e.from], &[e.from | &1])
      end)

    walk([start], adjacency, MapSet.new([start]))
  end

  defp walk([], _adjacency, seen), do: seen

  defp walk([id | rest], adjacency, seen) do
    next = adjacency |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(next ++ rest, adjacency, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  defp components(ids, edges) do
    adjacency =
      Enum.reduce(edges, Map.new(ids, &{&1, []}), fn e, acc ->
        acc |> Map.update!(e.from, &[e.to | &1]) |> Map.update!(e.to, &[e.from | &1])
      end)

    {groups, _seen} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {groups, seen} ->
        if MapSet.member?(seen, id) do
          {groups, seen}
        else
          group = walk([id], adjacency, MapSet.new([id]))
          {[Enum.filter(ids, &MapSet.member?(group, &1)) | groups], MapSet.union(seen, group)}
        end
      end)

    Enum.reverse(groups)
  end

  defp slack(e, ranks), do: Map.fetch!(ranks, e.to) - Map.fetch!(ranks, e.from) - e.minlen

  defp shift(ranks, nodes, delta),
    do:
      Map.new(ranks, fn {id, r} -> {id, if(MapSet.member?(nodes, id), do: r + delta, else: r)} end)
end
