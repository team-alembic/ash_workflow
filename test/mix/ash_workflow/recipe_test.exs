defmodule Mix.AshWorkflow.RecipeTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.Domain
  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.Invoice
  alias AshWorkflowTest.RecipeFixtures.NoDataLayer.User
  alias Mix.AshWorkflow.Recipe

  @fixtures "test/support/recipe_fixtures/no_data_layer"

  for {task, argv} <- [
        {"ash_workflow.gen.approval", ["--approver", inspect(User)]},
        {"ash_workflow.gen.expiry", []},
        {"ash_workflow.gen.sync", []}
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
        {"ash_workflow.gen.expiry", []},
        {"ash_workflow.gen.sync", []}
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

  describe "add_subject_change/4" do
    @contract "test/support/recipe_fixtures/expiry/contract.ex"
    @change "{MyApp.Changes.Stamp, days: 30}"

    defp contract_project(block \\ nil) do
      source =
        case block do
          nil ->
            File.read!(@contract)

          block ->
            String.replace(File.read!(@contract), "  attributes do", block <> "\n  attributes do")
        end

      Igniter.Test.test_project(app_name: :ash_workflow, files: %{@contract => source})
    end

    defp add_change(igniter, change, opts) do
      {:ok, applied, result} =
        igniter
        |> Recipe.add_subject_change(AshWorkflowTest.RecipeFixtures.Expiry.Contract, change, opts)
        |> Igniter.Test.apply_igniter()

      {applied, result.warnings, applied.assigns.test_files[@contract]}
    end

    defp global_changes(source) do
      {_ast, changes} =
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:changes, _meta, [[do: body]]} = node, _acc -> {node, block_calls(body)}
          node, acc -> {node, acc}
        end)

      Enum.map(changes, &Macro.to_string/1)
    end

    defp block_calls({:__block__, _meta, calls}), do: calls
    defp block_calls(call), do: [call]

    test "creates the changes block when the subject has none" do
      {_igniter, warnings, source} = add_change(contract_project(), @change, on: [:create])

      assert warnings == []
      assert source =~ "changes do"
      assert global_changes(source) == ["change({MyApp.Changes.Stamp, days: 30}, on: [:create])"]
    end

    test "keeps the changes already in the block, and writes a where: option" do
      {_igniter, warnings, source} =
        """
          changes do
            change set_attribute(:renamed?, false), on: [:create]
          end
        """
        |> contract_project()
        |> add_change(quote(do: MyApp.Changes.Stamp),
          on: [:create, :update],
          where: "[changing(:title)]"
        )

      assert warnings == []

      assert global_changes(source) == [
               "change(set_attribute(:renamed?, false), on: [:create])",
               "change(MyApp.Changes.Stamp, on: [:create, :update], where: [changing(:title)])"
             ]
    end

    test "skips an identical change without a warning" do
      {first, [], source} = add_change(contract_project(), @change, on: [:create])
      {_second, warnings, again} = add_change(first, @change, on: [:create])

      assert warnings == []
      assert again == source
    end

    test "warns and leaves a change of the same module with other options" do
      {_igniter, warnings, source} =
        """
          changes do
            change {MyApp.Changes.Stamp, days: 7}, on: [:update]
          end
        """
        |> contract_project()
        |> add_change(@change, on: [:create])

      assert [warning] = warnings
      assert warning =~ "AshWorkflowTest.RecipeFixtures.Expiry.Contract already has a change"
      assert warning =~ "{MyApp.Changes.Stamp, days: 7}"
      assert warning =~ "change {MyApp.Changes.Stamp, days: 30}, on: [:create]"

      assert global_changes(source) == ["change({MyApp.Changes.Stamp, days: 7}, on: [:update])"]
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

  describe "belongs_to/4" do
    test "writes a required belongs_to by default" do
      assert Recipe.belongs_to(:subject, MyApp.Invoice, :uuid) ==
               "belongs_to :subject, MyApp.Invoice, allow_nil?: false, public?: true, attribute_type: :uuid"
    end

    test "writes a nullable belongs_to when given allow_nil?: true" do
      assert Recipe.belongs_to(:subject, MyApp.Invoice, nil, allow_nil?: true) ==
               "belongs_to :subject, MyApp.Invoice, allow_nil?: true, public?: true"
    end
  end

  describe "parse_duration/2" do
    for {value, duration} <- [
          {"10s", {10, :seconds}},
          {"30m", {30, :minutes}},
          {"12h", {12, :hours}},
          {"2d", {2, :days}},
          {"2w", {14, :days}}
        ] do
      test "parses #{value} as #{inspect(duration)}" do
        assert Recipe.parse_duration(unquote(value), "--after") ==
                 {:ok, unquote(Macro.escape(duration))}
      end
    end

    test "returns nil when the flag is not given" do
      assert Recipe.parse_duration(nil, "--after") == {:ok, nil}
    end

    for value <- ["0s", "10", "2y", "-1d"] do
      test "rejects #{value}, naming the flag" do
        assert {:error, message} = Recipe.parse_duration(unquote(value), "--after")
        assert message =~ "--after must look like 10s, 30m, 12h, 2d or 2w"
      end
    end
  end

  describe "validate_max_attempts/1" do
    test "accepts a positive integer" do
      assert Recipe.validate_max_attempts(1) == :ok
      assert Recipe.validate_max_attempts(5) == :ok
    end

    for value <- [0, -1, nil, "3"] do
      test "rejects #{inspect(value)}" do
        assert {:error, message} = Recipe.validate_max_attempts(unquote(value))
        assert message =~ "--max-attempts must be a positive integer"
      end
    end
  end
end
