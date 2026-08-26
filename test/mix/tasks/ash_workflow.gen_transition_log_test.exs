defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLogTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Igniter.Project.Module, as: ProjectModule

  @moduletag :igniter

  defp project(extra_files \\ %{}) do
    files =
      Map.merge(
        %{
          "test/support/domain.ex" => File.read!("test/support/domain.ex"),
          "test/support/workflow.ex" => File.read!("test/support/workflow.ex")
        },
        extra_files
      )

    test_project(app_name: :ash_workflow, files: files)
  end

  defp source!(igniter, module) do
    {:ok, {igniter, source, _zipper}} = ProjectModule.find_module(igniter, module)
    {igniter, Rewrite.Source.get(source, :content)}
  end

  test "generates a log resource matching the workflow's ETS data layer and domain" do
    igniter =
      project()
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.Workflow"
      ])
      |> apply_igniter!()

    {igniter, content} = source!(igniter, AshWorkflowTest.WorkflowTransition)

    assert content =~ "domain: AshWorkflowTest.Domain"
    assert content =~ "data_layer: Ash.DataLayer.Ets"
    assert content =~ "attribute(:from_state, :atom"
    assert content =~ "attribute(:to_state, :atom, allow_nil?: false"
    assert content =~ "attribute(:transition_name, :atom, allow_nil?: false"
    assert content =~ "attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false"
    assert content =~ "attribute(:triggered_by, :atom, allow_nil?: false"
    assert content =~ "belongs_to(:workflow, AshWorkflowTest.Workflow"
    assert content =~ "create :create do"
    assert content =~ ":workflow_id"

    {_igniter, domain_content} = source!(igniter, AshWorkflowTest.Domain)
    assert domain_content =~ "AshWorkflowTest.WorkflowTransition"
  end

  test "adds the transition_log entry to the workflow resource's workflow block" do
    igniter =
      project()
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.Workflow"
      ])
      |> apply_igniter!()

    {_igniter, content} = source!(igniter, AshWorkflowTest.Workflow)

    assert content =~ "transition_log(AshWorkflowTest.WorkflowTransition)"
  end

  test "respects --log-module" do
    igniter =
      project()
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.Workflow",
        "--log-module",
        "AshWorkflowTest.CustomLog"
      ])
      |> apply_igniter!()

    {_igniter, content} = source!(igniter, AshWorkflowTest.CustomLog)
    assert content =~ "belongs_to(:workflow, AshWorkflowTest.Workflow"

    {_igniter, workflow_content} = source!(igniter, AshWorkflowTest.Workflow)
    assert workflow_content =~ "transition_log(AshWorkflowTest.CustomLog)"
  end

  test "--actor adds belongs_to_actor and a matching relationship" do
    igniter =
      project(%{"test/support/reviewer.ex" => File.read!("test/support/reviewer.ex")})
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.Workflow",
        "--actor",
        "AshWorkflowTest.Reviewer"
      ])
      |> apply_igniter!()

    {igniter, content} = source!(igniter, AshWorkflowTest.WorkflowTransition)
    assert content =~ "belongs_to(:reviewer, AshWorkflowTest.Reviewer"
    assert content =~ ":reviewer_id"

    {_igniter, workflow_content} = source!(igniter, AshWorkflowTest.Workflow)
    assert workflow_content =~ "belongs_to_actor(:reviewer, AshWorkflowTest.Reviewer)"
  end

  test "generates a Postgres-backed log resource reusing the workflow's table and repo" do
    igniter =
      project(%{
        "test/support/postgres/domain.ex" => File.read!("test/support/postgres/domain.ex"),
        "test/support/postgres/approval_workflow.ex" =>
          File.read!("test/support/postgres/approval_workflow.ex")
      })
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.Postgres.ApprovalWorkflow"
      ])
      |> apply_igniter!()

    {_igniter, content} =
      source!(igniter, AshWorkflowTest.Postgres.ApprovalWorkflowTransition)

    assert content =~ "data_layer: AshPostgres.DataLayer"
    assert content =~ "repo(AshWorkflowTest.Repo)"
    assert content =~ "table(\"approval_workflows_transitions\")"
    assert content =~ "index([:workflow_id, :occurred_at])"
  end

  test "warns instead of duplicating when a transition_log is already configured" do
    igniter =
      project(%{
        "test/support/workflows/logged_workflow.ex" =>
          File.read!("test/support/workflows/logged_workflow.ex"),
        "test/support/workflows/logged_transition.ex" =>
          File.read!("test/support/workflows/logged_transition.ex"),
        "test/support/reviewer.ex" => File.read!("test/support/reviewer.ex")
      })
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [
        "AshWorkflowTest.LoggedWorkflow"
      ])

    assert Enum.any?(igniter.warnings, &String.contains?(&1, "already has a `transition_log`"))
  end
end
