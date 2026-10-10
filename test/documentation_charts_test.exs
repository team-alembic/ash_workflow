defmodule AshWorkflow.DocumentationChartsTest do
  @moduledoc """
  Guards the generated chart examples in the guides against the chart code
  and the example workflows moving underneath them. See
  `AshWorkflowTest.ChartExamples`.
  """
  use ExUnit.Case, async: true

  alias AshWorkflowTest.ChartExamples

  for file <- ChartExamples.files() do
    test "#{file} has up-to-date chart examples" do
      contents = File.read!(unquote(file))

      assert ChartExamples.render(contents) == contents, """
      #{unquote(file)} has a generated chart example that no longer matches \
      AshWorkflow.Charts. Run bin/update-chart-examples and commit the result.
      """
    end
  end

  test "the diagrams guide keeps its generated examples" do
    assert "documentation/topics/diagrams.md" |> File.read!() |> ChartExamples.count() == 11
  end

  for {file, resource, _format, _opts} <- ChartExamples.svgs() do
    test "#{file} is an SVG of #{inspect(resource)}" do
      svg = File.read!(unquote(file))

      # D2 writes the shape keys in base64, so check a label the chart shows.
      # The root needs a width and a height, or an <img> tag draws it in a tiny
      # default box. D2 writes them in pixels, and Graphviz in points.
      [root] = Regex.run(~r/<svg [^>]*>/, svg)
      assert root =~ ~r/ width="\d+(pt)?"/
      assert root =~ ~r/ height="\d+(pt)?"/
      assert svg =~ "undo within 1 hour"
    end
  end

  test "the workflow format copies the real block, not a moduledoc sample" do
    block = ChartExamples.block(AshWorkflowTest.ChartKeywordWorkflow, :workflow)

    assert block =~ "```elixir\nworkflow do\n  step :note do\n"
    refute block =~ "step :sample"
  end

  test "a block without its closing marker is left alone and not counted" do
    contents = """
    <!-- chart: BasicWorkflow.DocumentApproval mermaid -->
    prose that a missing closer must not swallow
    <!-- chart: BasicWorkflow.DocumentApproval json -->
    stale
    <!-- /chart -->
    """

    rendered = ChartExamples.render(contents)

    assert rendered =~ "prose that a missing closer must not swallow"
    assert rendered =~ "```json\n"
    assert ChartExamples.count(contents) == 1
  end

  test "render/1 fills a marked block and leaves the markers" do
    contents = """
    before
    <!-- chart: BasicWorkflow.DocumentApproval mermaid -->
    stale
    <!-- /chart -->
    after
    """

    rendered = ChartExamples.render(contents)

    assert rendered =~ "before\n<!-- chart: BasicWorkflow.DocumentApproval mermaid -->\n"
    assert rendered =~ "```mermaid\nstateDiagram-v2\n"
    assert rendered =~ "```\n<!-- /chart -->\nafter\n"
    refute rendered =~ "stale"
    assert ChartExamples.render(rendered) == rendered
  end
end
