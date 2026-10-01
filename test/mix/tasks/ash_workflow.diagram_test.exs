defmodule Mix.Tasks.AshWorkflow.DiagramTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AshWorkflow.Charts
  alias Mix.Tasks.AshWorkflow.Diagram

  test "prints a Mermaid diagram of a named resource" do
    output = capture_io(fn -> Diagram.run(["AshWorkflowTest.PolicyWorkflow"]) end)

    assert output == Charts.render(AshWorkflowTest.PolicyWorkflow, :mermaid) <> "\n"
  end

  test "prints JSON with --format json" do
    output =
      capture_io(fn -> Diagram.run(["--format", "json", "AshWorkflowTest.PolicyWorkflow"]) end)

    assert %{"resource" => "AshWorkflowTest.PolicyWorkflow"} = Jason.decode!(output)
  end

  test "prints one JSON document per line for several resources" do
    output =
      capture_io(fn ->
        Diagram.run([
          "--format",
          "json",
          "AshWorkflowTest.PolicyWorkflow",
          "AshWorkflowTest.ChartKeywordWorkflow"
        ])
      end)

    assert output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["resource"]) ==
             ["AshWorkflowTest.PolicyWorkflow", "AshWorkflowTest.ChartKeywordWorkflow"]
  end

  test "--no-undo and --no-notes reach the graph" do
    output =
      capture_io(fn ->
        Diagram.run(["--no-undo", "--no-notes", "AshWorkflowTest.UndoWorkflow"])
      end)

    refute output =~ "↶ undo"
    refute output =~ "note right of"
  end

  @tag :tmp_dir
  test "--output writes one file per workflow resource in the configured domains",
       %{tmp_dir: dir} do
    capture_io(fn -> Diagram.run(["--output", dir]) end)

    files = File.ls!(dir)

    assert "AshWorkflowTest.FullPipeline.mmd" in files
    refute Enum.any?(files, &String.starts_with?(&1, "AshWorkflowTest.Reviewer."))

    assert File.read!(Path.join(dir, "AshWorkflowTest.FullPipeline.mmd")) ==
             Charts.render(AshWorkflowTest.FullPipeline, :mermaid)
  end

  test "raises for a module that does not exist" do
    assert_raise Mix.Error, ~r/Module NoSuch.Module could not be loaded/, fn ->
      Diagram.run(["NoSuch.Module"])
    end
  end

  test "raises for a module that is not a workflow resource" do
    assert_raise Mix.Error,
                 ~r/AshWorkflowTest.Reviewer is not a resource that uses AshWorkflow/,
                 fn ->
                   Diagram.run(["AshWorkflowTest.Reviewer"])
                 end
  end

  test "raises for an unknown format or option" do
    assert_raise Mix.Error, ~r/Unknown format "svg"/, fn ->
      Diagram.run(["--format", "svg", "AshWorkflowTest.PolicyWorkflow"])
    end

    assert_raise Mix.Error, ~r/Unknown options/, fn -> Diagram.run(["--bogus"]) end
  end
end
