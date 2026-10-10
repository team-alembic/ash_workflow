defmodule Mix.Tasks.AshWorkflow.DiagramConfigTest do
  # These tests change the application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AshWorkflow.Diagram

  setup do
    previous = Application.get_env(:ash_workflow, :dot)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_workflow, :dot, previous),
        else: Application.delete_env(:ash_workflow, :dot)
    end)
  end

  @tag :tmp_dir
  test "a dark theme from the DOT config adds -dark to the file name", %{tmp_dir: dir} do
    Application.put_env(:ash_workflow, :dot, theme: :dark)

    capture_io(fn ->
      Diagram.run(["--format", "dot", "--output", dir, "AshWorkflowTest.PolicyWorkflow"])
    end)

    assert File.ls!(dir) == ["AshWorkflowTest.PolicyWorkflow-dark.dot"]

    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow-dark.dot")) =~
             ~S(bgcolor="#1E1E2E")
  end

  @tag :tmp_dir
  test "a chart that cannot be drawn raises a Mix error and creates no --output directory",
       %{tmp_dir: dir} do
    Application.put_env(:ash_workflow, :dot, path: "no-such-dot-command")
    output = Path.join(dir, "diagrams")

    assert_raise Mix.Error, ~r/sets :path to "no-such-dot-command"/, fn ->
      Diagram.run([
        "--format",
        "dot",
        "--svg",
        "--output",
        output,
        "AshWorkflowTest.PolicyWorkflow"
      ])
    end

    refute File.exists?(output)
  end

  test "a bad theme in the DOT config raises a Mix error" do
    Application.put_env(:ash_workflow, :dot, theme: :sepia)

    assert_raise Mix.Error, "theme must be :light or :dark, got: :sepia", fn ->
      Diagram.run(["--format", "dot", "AshWorkflowTest.PolicyWorkflow"])
    end
  end
end
