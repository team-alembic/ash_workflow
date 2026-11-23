defmodule Mix.Tasks.AshWorkflow.DiagramConfigTest do
  # These tests change the application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AshWorkflow.Diagram

  setup do
    for format <- [:d2, :dot] do
      previous = Application.get_env(:ash_workflow, format)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_workflow, format, previous),
          else: Application.delete_env(:ash_workflow, format)
      end)
    end

    :ok
  end

  @tag :tmp_dir
  test "a dark theme from the config adds -dark to the file name too", %{tmp_dir: dir} do
    Application.put_env(:ash_workflow, :d2, theme: :dark)

    capture_io(fn ->
      Diagram.run(["--format", "d2", "--output", dir, "AshWorkflowTest.PolicyWorkflow"])

      Diagram.run([
        "--format",
        "d2",
        "--theme",
        "light",
        "--output",
        dir,
        "AshWorkflowTest.PolicyWorkflow"
      ])
    end)

    assert Enum.sort(File.ls!(dir)) ==
             ["AshWorkflowTest.PolicyWorkflow-dark.d2", "AshWorkflowTest.PolicyWorkflow.d2"]

    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow-dark.d2")) =~ "theme-id: 200"
    assert File.read!(Path.join(dir, "AshWorkflowTest.PolicyWorkflow.d2")) =~ "theme-id: 0"
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

  @tag :tmp_dir
  test "a D2 chart that cannot be drawn raises a Mix error and creates no --output directory",
       %{tmp_dir: dir} do
    Application.put_env(:ash_workflow, :d2, path: "no-such-d2-command")
    output = Path.join(dir, "diagrams")

    assert_raise Mix.Error, ~r/sets :path to "no-such-d2-command"/, fn ->
      Diagram.run([
        "--format",
        "d2",
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
