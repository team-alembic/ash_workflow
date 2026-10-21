defmodule AshWorkflow.Charts.SvgTest do
  use ExUnit.Case, async: true

  alias AshWorkflow.Charts
  alias AshWorkflow.Charts.Svg

  # :xmerl is not on the code path of this project, so load it here, and call
  # it through apply/3 so the compiler does not warn about it.
  setup_all do
    Mix.ensure_application!(:xmerl)
    :ok
  end

  @examples [
    BasicWorkflow.DocumentApproval,
    BasicWorkflow.Incident,
    BasicWorkflow.Subscription,
    BasicWorkflow.ScheduledPost
  ]

  test "draws each guide workflow as well-formed SVG in both themes" do
    for resource <- @examples, theme <- [:light, :dark] do
      svg = Charts.render(resource, Svg, theme: theme)

      assert well_formed?(svg)
      assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
    end
  end

  test "no two boxes overlap" do
    for resource <- @examples do
      {result, _edges} = resource |> Charts.graph() |> Svg.layout()
      assert Svg.overlaps(result) == []
    end
  end

  test "the same workflow gives the same bytes" do
    assert Charts.render(BasicWorkflow.Incident, Svg) ==
             Charts.render(BasicWorkflow.Incident, Svg)
  end

  test "shows each step name and each edge label" do
    graph = Charts.graph(BasicWorkflow.DocumentApproval)
    svg = Charts.render(BasicWorkflow.DocumentApproval, Svg)

    for node <- graph.nodes, do: assert(svg =~ ">#{node.id}<")
    for edge <- graph.edges, do: assert(svg =~ edge.label)
  end

  defp well_formed?(svg) do
    match?({_doc, []}, apply(:xmerl_scan, :string, [:binary.bin_to_list(svg), [quiet: true]]))
  end
end
