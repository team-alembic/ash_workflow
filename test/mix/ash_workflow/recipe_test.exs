defmodule Mix.AshWorkflow.RecipeTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.Domain
  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.Invoice
  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.User
  alias Mix.AshWorkflow.Recipe

  @fixtures "test/support/recipe_fixtures/no_data_layer"

  for {task, argv} <- [
        {"ash_workflow.gen.approval", ["--approver", inspect(User)]},
        {"ash_workflow.gen.expiry", []}
      ] do
    test "#{task} stops when a missing subject has no data layer to copy" do
      igniter =
        ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex"]
        |> project()
        |> Igniter.compose_task(
          unquote(task),
          [inspect(Invoice), "--domain", inspect(Domain) | unquote(argv)]
        )

      assert [issue] = igniter.issues
      assert issue =~ "#{inspect(Invoice)} does not exist"
      assert issue =~ "Create #{inspect(Invoice)} first"
      assert issue =~ "--domain that has an ETS or Postgres resource"

      assert {:error, _issues} = Igniter.Test.apply_igniter(igniter)
      assert igniter.tasks == []
      assert Enum.filter(Rewrite.sources(igniter.rewrite), &Rewrite.Source.updated?/1) == []
    end
  end

  for {task, argv} <- [
        {"ash_workflow.gen.approval", ["--approver", inspect(User)]},
        {"ash_workflow.gen.expiry", []}
      ] do
    test "#{task} stops when an existing subject has no data layer" do
      igniter =
        ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex"]
        |> project()
        |> Igniter.compose_task(unquote(task), [inspect(User) | unquote(argv)])

      assert [issue] = igniter.issues
      assert issue =~ "#{inspect(User)} has no data layer"

      assert {:error, _issues} = Igniter.Test.apply_igniter(igniter)
      assert Enum.filter(Rewrite.sources(igniter.rewrite), &Rewrite.Source.updated?/1) == []
    end
  end

  describe "postgres_block/3" do
    @storage %{domain: Domain, data_layer: AshPostgres.DataLayer, repo: AshWorkflowTest.Repo}

    for {module, table} <- [
          {MyApp.ExpenseApproval, "expense_approvals"},
          {MyApp.ExpenseApprovalDecision, "expense_approval_decisions"},
          {MyApp.ContractExpiry, "contract_expiries"},
          {MyApp.Holiday, "holidays"},
          {MyApp.Status, "statuses"},
          {MyApp.Box, "boxes"},
          {MyApp.Waltz, "waltzes"},
          {MyApp.Batch, "batches"},
          {MyApp.Wish, "wishes"}
        ] do
      test "names the table for #{inspect(module)} #{table}" do
        assert Recipe.postgres_block(@storage, unquote(module)) =~
                 "table #{inspect(unquote(table))}"
      end
    end
  end
end
