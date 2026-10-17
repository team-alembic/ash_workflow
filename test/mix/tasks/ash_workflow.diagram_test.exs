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

  test "prints D2 with --format d2" do
    output =
      capture_io(fn -> Diagram.run(["--format", "d2", "AshWorkflowTest.PolicyWorkflow"]) end)

    assert output == Charts.render(AshWorkflowTest.PolicyWorkflow, :d2) <> "\n"
  end

  test "prints DOT with --format dot" do
    output =
      capture_io(fn -> Diagram.run(["--format", "dot", "AshWorkflowTest.PolicyWorkflow"]) end)

    assert output == Charts.render(AshWorkflowTest.PolicyWorkflow, :dot) <> "\n"
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

  test "--theme dark reaches the D2 and DOT backends, and needs --format d2 or dot" do
    output =
      capture_io(fn ->
        Diagram.run(["--format", "d2", "--theme", "dark", "AshWorkflowTest.PolicyWorkflow"])
      end)

    assert output =~ "theme-id: 200"

    output =
      capture_io(fn ->
        Diagram.run(["--format", "dot", "--theme", "dark", "AshWorkflowTest.PolicyWorkflow"])
      end)

    assert output =~ ~S(bgcolor="#1E1E2E")

    assert_raise Mix.Error, ~r/--theme must be light or dark/, fn ->
      Diagram.run(["--format", "d2", "--theme", "sepia", "AshWorkflowTest.PolicyWorkflow"])
    end

    assert_raise Mix.Error, ~r/--theme needs --format d2 or dot, not mermaid/, fn ->
      Diagram.run(["--theme", "dark", "AshWorkflowTest.PolicyWorkflow"])
    end
  end

  @tag :tmp_dir
  test "--theme dark adds -dark to the file name, so it does not overwrite the light file",
       %{tmp_dir: dir} do
    capture_io(fn ->
      for theme <- ["light", "dark"] do
        Diagram.run([
          "--format",
          "d2",
          "--theme",
          theme,
          "--output",
          dir,
          "AshWorkflowTest.PolicyWorkflow"
        ])
      end
    end)

    assert Enum.sort(File.ls!(dir)) ==
             ["AshWorkflowTest.PolicyWorkflow-dark.d2", "AshWorkflowTest.PolicyWorkflow.d2"]

    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow-dark.d2")) ==
             Charts.render(AshWorkflowTest.PolicyWorkflow, :d2, theme: :dark)

    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow.d2")) ==
             Charts.render(AshWorkflowTest.PolicyWorkflow, :d2, theme: :light)
  end

  test "--svg needs --format d2 or dot" do
    assert_raise Mix.Error, ~r/--svg needs --format d2 or dot, not mermaid/, fn ->
      Diagram.run(["--svg", "AshWorkflowTest.PolicyWorkflow"])
    end
  end

  @tag :tmp_dir
  @tag :d2
  test "--format d2 --svg writes .svg files that d2 drew", %{tmp_dir: dir} do
    capture_io(fn ->
      Diagram.run(["--format", "d2", "--svg", "--output", dir, "AshWorkflowTest.PolicyWorkflow"])
    end)

    assert File.ls!(dir) == ["AshWorkflowTest.PolicyWorkflow.svg"]
    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow.svg")) =~ "<svg"
  end

  @tag :tmp_dir
  @tag :dot
  test "--format dot --svg writes .svg files that dot drew", %{tmp_dir: dir} do
    capture_io(fn ->
      Diagram.run(["--format", "dot", "--svg", "--output", dir, "AshWorkflowTest.PolicyWorkflow"])
    end)

    assert File.ls!(dir) == ["AshWorkflowTest.PolicyWorkflow.svg"]
    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow.svg")) =~ "<svg"
  end
end
