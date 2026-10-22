defmodule Mix.AshWorkflow.RecipeIntervalTest do
  # Changes the :ash_workflow scheduler app env, which every workflow compiled
  # meanwhile would read.
  use AshWorkflow.RecipeCase, async: false

  alias AshWorkflowTest.RecipeFixtures.Approval.Expense
  alias AshWorkflowTest.RecipeFixtures.Approval.User

  @fixtures "test/support/recipe_fixtures/approval"
  @files Enum.map(~w(domain user receipt ledger_line expense), &"#{@fixtures}/#{&1}.ex")

  setup do
    previous = Application.fetch_env(:ash_workflow, :scheduler)

    on_exit(fn ->
      case previous do
        {:ok, scheduler} -> Application.put_env(:ash_workflow, :scheduler, scheduler)
        :error -> Application.delete_env(:ash_workflow, :scheduler)
      end
    end)
  end

  defp approval(overdue_after) do
    @files
    |> project()
    |> Igniter.compose_task("ash_workflow.gen.approval", [
      inspect(Expense),
      "--approver",
      inspect(User),
      "--overdue-after",
      overdue_after
    ])
  end

  test "reports an --overdue-after below the default scheduler's floor" do
    Application.delete_env(:ash_workflow, :scheduler)

    assert [issue] = approval("30s").issues
    assert issue =~ "--overdue-after is shorter than AshWorkflow.Scheduler.Oban can honour"
    assert issue =~ "60000ms"
    assert issue =~ "AshWorkflow.Scheduler.Precise"
  end

  test "accepts an --overdue-after at the default scheduler's floor" do
    Application.delete_env(:ash_workflow, :scheduler)

    assert approval("60s").issues == []
  end

  test "accepts a short --overdue-after when Precise is configured" do
    Application.put_env(:ash_workflow, :scheduler, AshWorkflow.Scheduler.Precise)

    assert approval("30s").issues == []
  end
end
