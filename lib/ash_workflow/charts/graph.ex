defmodule AshWorkflow.Charts.Graph do
  @moduledoc """
  The diagram model every `AshWorkflow.Charts` backend draws from.

  `build/2` reads `AshWorkflow.Info.workflow_graph/1` and
  `AshWorkflow.Info.undoable_edges/1` once, and flattens them into a list of
  `AshWorkflow.Charts.Graph.Node` and a list of `AshWorkflow.Charts.Graph.Edge`,
  with every label already written out. A backend only maps each node kind and
  edge kind to its own syntax, so every format shows the same workflow in the
  same words.

  Nodes are in step declaration order. Edges are grouped by the step they
  leave, in declaration order, and undo edges come last. Within one step the
  order is `on_success` routes, transitions, timeouts that move the record,
  then `on_error`.

  ## Options

  * `:undo` — include an edge for each move the generated `undo` action can
    rewind. Defaults to `true`. Has no effect on a workflow without an `undo`
    block.
  * `:notes` — include each step's notes. Defaults to `true`.
  """

  alias AshWorkflow.Charts.Format
  alias AshWorkflow.Charts.Graph.Edge
  alias AshWorkflow.Charts.Graph.Node
  alias AshWorkflow.Charts.Graph.Note
  alias AshWorkflow.Info

  defstruct [:resource, nodes: [], edges: []]

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          nodes: [Node.t()],
          edges: [Edge.t()]
        }

  @doc """
  Builds the diagram model for a resource that uses `AshWorkflow`.

  Raises `ArgumentError` for a module that is not such a resource.
  """
  @spec build(Ash.Resource.t(), keyword()) :: t()
  def build(resource, opts \\ []) do
    opts = Keyword.validate!(opts, undo: true, notes: true)

    if not Info.workflow?(resource) do
      raise ArgumentError, "#{inspect(resource)} is not a resource that uses AshWorkflow"
    end

    graph = Info.workflow_graph(resource)
    entries = resource |> Info.steps() |> Enum.map(&Map.fetch!(graph, &1.name))

    %__MODULE__{
      resource: resource,
      nodes: Enum.map(entries, &to_node(&1, opts[:notes])),
      edges: Enum.flat_map(entries, &edges/1) ++ undo_edges(resource, opts[:undo])
    }
  end

  defp to_node(entry, notes?) do
    %Node{
      id: entry.name,
      kind: kind(entry),
      initial?: entry.initial,
      notes: if(notes?, do: notes(entry), else: [])
    }
  end

  defp kind(%{terminal: true}), do: :terminal
  defp kind(%{wait_state: true}), do: :wait_state
  defp kind(%{manual: true}), do: :manual
  defp kind(_entry), do: :automatic

  defp notes(entry) do
    optional_note(:policy, Format.policy(entry.policy)) ++
      optional_note(:retry, Format.retry(entry.retry)) ++
      timeout_notes(entry) ++ every_notes(entry)
  end

  defp optional_note(_kind, nil), do: []
  defp optional_note(kind, label), do: [%Note{kind: kind, label: label}]

  defp timeout_notes(entry) do
    for %{to: nil} = timeout <- entry.timeouts do
      %Note{
        kind: :timeout,
        name: timeout.name,
        action: timeout.action,
        label: Format.deadline(timeout),
        retry: Format.retry(timeout.retry)
      }
    end
  end

  defp every_notes(entry) do
    for every <- entry.everys do
      %Note{
        kind: :every,
        name: every.name,
        action: every.action,
        label: Format.every(every),
        retry: Format.retry(every.retry)
      }
    end
  end

  defp edges(entry) do
    on_success_edges(entry) ++
      transition_edges(entry) ++ timeout_edges(entry) ++ on_error_edges(entry)
  end

  defp on_success_edges(entry) do
    for route <- entry.on_success do
      %Edge{
        from: entry.name,
        to: route.to,
        kind: :on_success,
        name: entry.action,
        label: to_string(entry.action),
        condition: Format.condition(route.condition),
        fallback?: fallback?(route, entry.on_success)
      }
    end
  end

  # A conditional `on_success` may end with a route that has no `when`. It is
  # taken only when no earlier route matched. A step with one unconditional
  # route has no fallback, because that route is always taken.
  defp fallback?(%{condition: nil}, [_single_route]), do: false
  defp fallback?(%{condition: nil}, _routes), do: true
  defp fallback?(_route, _routes), do: false

  defp transition_edges(entry) do
    for transition <- entry.transitions do
      %Edge{
        from: entry.name,
        to: transition.to,
        kind: :transition,
        name: transition.name,
        label: to_string(transition.name),
        condition: Format.condition(transition.condition)
      }
    end
  end

  defp timeout_edges(entry) do
    for %{to: to} = timeout <- entry.timeouts, not is_nil(to) do
      %Edge{
        from: entry.name,
        to: to,
        kind: :timeout,
        name: timeout.name,
        label: Format.deadline(timeout)
      }
    end
  end

  defp on_error_edges(%{on_error: nil}), do: []

  defp on_error_edges(entry) do
    [
      %Edge{
        from: entry.name,
        to: entry.on_error,
        kind: :on_error,
        name: entry.action,
        label: "on_error"
      }
    ]
  end

  defp undo_edges(_resource, false), do: []

  defp undo_edges(resource, true) do
    for {from, to} <- Info.undoable_edges(resource) do
      %Edge{from: to, to: from, kind: :undo, name: :undo, label: "undo"}
    end
  end
end
