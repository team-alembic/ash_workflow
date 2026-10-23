with {:module, _} <- Code.ensure_loaded(Clarity.Vertex.Util) do
  defmodule AshWorkflow.Clarity.Markdown do
    @moduledoc false

    alias AshWorkflow.Charts.Graph.Edge
    alias Clarity.Vertex.Util

    @spec step_link(Ash.Resource.t(), atom()) :: iodata()
    def step_link(resource, step_name) do
      link(code(step_name), Util.id(AshWorkflow.Clarity.Vertex.Step, [resource, step_name]))
    end

    @spec action_link(Ash.Resource.t(), atom() | nil) :: iodata()
    def action_link(_resource, nil), do: "—"

    def action_link(resource, action_name) do
      link(code(action_name), Util.id(Clarity.Vertex.Ash.Action, [resource, action_name]))
    end

    @spec resource_link(Ash.Resource.t()) :: iodata()
    def resource_link(resource) do
      link(code(resource), Util.id(Clarity.Vertex.Ash.Resource, [resource]))
    end

    @spec code(term()) :: iodata()
    def code(value) when is_atom(value) and not is_nil(value) do
      case Atom.to_string(value) do
        "Elixir." <> _ -> ["`", inspect(value), "`"]
        name -> ["`", name, "`"]
      end
    end

    def code(value) when is_binary(value), do: ["`", cell(value), "`"]

    @spec cell(String.t() | nil) :: String.t()
    def cell(nil), do: "—"
    def cell(text), do: String.replace(text, "|", "\\|")

    @spec table([String.t()], [[iodata()]]) :: iodata()
    def table(_headers, []), do: []

    def table(headers, rows) do
      [
        "| ",
        Enum.intersperse(headers, " | "),
        " |\n|",
        Enum.map(headers, fn _ -> " --- |" end),
        "\n",
        Enum.map(rows, &["| ", Enum.intersperse(&1, " | "), " |\n"]),
        "\n"
      ]
    end

    @spec edge_kind(Edge.kind()) :: String.t()
    def edge_kind(:transition), do: "✋ transition"
    def edge_kind(:on_success), do: "⚙ on_success"
    def edge_kind(:on_error), do: "✖ on_error"
    def edge_kind(:timeout), do: "⏱ timeout"
    def edge_kind(:undo), do: "↶ undo"

    @spec edge_condition(Edge.t()) :: iodata()
    def edge_condition(%Edge{fallback?: true}), do: "otherwise"
    def edge_condition(%Edge{condition: nil}), do: "—"
    def edge_condition(%Edge{condition: condition}), do: code(condition)

    @spec edge_trigger(Edge.t()) :: iodata()
    def edge_trigger(%Edge{kind: :timeout} = edge), do: [code(edge.name), " ", edge.label]
    def edge_trigger(%Edge{kind: :undo, label: label}), do: label
    def edge_trigger(%Edge{name: name}), do: code(name)

    defp link(text, vertex_id), do: ["[", text, "](vertex://", vertex_id, ")"]
  end
end
