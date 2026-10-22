defmodule Mix.Tasks.AshWorkflow.Gen.ApprovalTest do
  use AshWorkflow.RecipeCase, async: true

  alias Ash.Error.Invalid.NoSuchInput
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Approval.Domain
  alias AshWorkflowTest.RecipeFixtures.Approval.Expense
  alias AshWorkflowTest.RecipeFixtures.Approval.ExpenseApproval
  alias AshWorkflowTest.RecipeFixtures.Approval.ExpenseApprovalDecision
  alias AshWorkflowTest.RecipeFixtures.Approval.ExpenseApprovalTransition
  alias AshWorkflowTest.RecipeFixtures.Approval.Invoice
  alias AshWorkflowTest.RecipeFixtures.Approval.LedgerLine
  alias AshWorkflowTest.RecipeFixtures.Approval.Receipt
  alias AshWorkflowTest.RecipeFixtures.Approval.User

  @fixtures "test/support/recipe_fixtures/approval"
  @domain_files Enum.map(~w(domain user receipt ledger_line), &"#{@fixtures}/#{&1}.ex")
  @files @domain_files ++ ["#{@fixtures}/expense.ex"]
  @checks "lib/ash_workflow_test/recipe_fixtures/approval/expense_approval/checks"
  @deny_all "def match?(_actor, _context, _opts), do: false"

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.approval", argv)
  end

  defp approval_for_expenses(tmp_dir, argv \\ []) do
    [inspect(Expense), "--approver", inspect(User) | argv]
    |> generate()
    |> allow_requesters()
    |> allow_approvers()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanRequest and CanApprove. Here any actor may open a request, and anyone
  # with the :approver role may decide.
  defp allow_requesters(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_request.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_approvers(recipe) do
    edit_source(recipe, "#{@checks}/can_approve.ex", fn source ->
      String.replace(
        source,
        @deny_all,
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :approver"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp user(recipe, role \\ :approver) do
    recipe.modules[User]
    |> Ash.Changeset.for_create(:create, %{name: "#{role}", role: role})
    |> Ash.create!()
  end

  defp expense(recipe) do
    recipe.modules[Expense]
    |> Ash.Changeset.for_create(:create, %{description: "Taxi", amount: 42})
    |> Ash.create!()
  end

  defp request(recipe, subject, requester) do
    recipe.modules[ExpenseApproval]
    |> Ash.Changeset.for_create(:request, %{subject_id: subject.id}, actor: requester)
    |> Ash.create!()
  end

  defp decide(approval, action, actor) do
    input = if action in [:approve, :reject], do: %{comment: "#{action}"}, else: %{}

    approval
    |> Ash.Changeset.for_update(action, input, actor: actor)
    |> Ash.update()
  end

  defp requested_days_ago(recipe, subject, requester, days) do
    recipe.modules[ExpenseApproval]
    |> Ash.Changeset.for_create(:request, %{subject_id: subject.id}, actor: requester)
    |> Ash.Changeset.force_change_attribute(
      :requested_at,
      DateTime.add(DateTime.utc_now(), -days, :day)
    )
    |> Ash.create!()
  end

  defp state(approval), do: Ash.get!(approval.__struct__, approval.id).state

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the three approval edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = approval_for_expenses(tmp_dir)
      subject = recipe.modules[Expense]

      assert attributes(subject) == attributes(Expense)
      assert actions(subject) == actions(Expense)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Expense)) == [:approvals, :latest_approval]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Expense)) == [:approved?]
    end

    test "is approved once its latest approval is", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir)
      expense = expense(recipe)

      assert Ash.load!(expense, :approved?).approved? == false

      approval = request(recipe, expense, user(recipe, :employee))
      assert Ash.load!(expense, :approved?).approved? == false

      assert {:ok, %{state: :approved}} = decide(approval, :approve, user(recipe))
      assert Ash.load!(expense, :approved?).approved? == true

      request(recipe, expense, user(recipe, :employee))
      assert Ash.load!(expense, :approved?).approved? == false
    end

    test "records each decision and transition with the actor who made it", %{
      tmp_dir: tmp_dir
    } do
      recipe = approval_for_expenses(tmp_dir)
      requester = user(recipe, :employee)
      approver = user(recipe)

      {:ok, _approved} =
        recipe |> request(expense(recipe), requester) |> decide(:approve, approver)

      assert [decision] = Ash.read!(recipe.modules[ExpenseApprovalDecision])
      assert {decision.approver_id, decision.decision} == {approver.id, :approved}
      assert decision.comment == "approve"

      log =
        recipe.modules[ExpenseApprovalTransition]
        |> Ash.Query.sort(occurred_at: :asc, id: :asc)
        |> Ash.read!()
        |> Enum.map(&{&1.to_state, &1.user_id})

      assert log == [pending: requester.id, approved: approver.id]
    end
  end

  test "creates a missing subject in the given domain and approves against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @domain_files
      |> generate([inspect(Invoice), "--approver", inspect(User), "--domain", inspect(Domain)])
      |> allow_requesters(
        "lib/ash_workflow_test/recipe_fixtures/approval/invoice_approval/checks"
      )
      |> compile(tmp_dir)

    invoice_module = recipe.modules[Invoice]
    approval_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Approval.InvoiceApproval]

    assert Ash.Resource.Info.data_layer(invoice_module) == Ash.DataLayer.Ets
    assert invoice_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    invoice = invoice_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    approval =
      approval_module
      |> Ash.Changeset.for_create(:request, %{subject_id: invoice.id},
        actor: user(recipe, :employee)
      )
      |> Ash.create!()

    assert approval.state == :pending
    assert Ash.load!(invoice, latest_approval: :id).latest_approval.id == approval.id
  end

  test "running the task a second time changes nothing" do
    first = generate([inspect(Expense), "--approver", inspect(User), "--overdue-after", "2d"])

    second =
      run_task(first.igniter, "ash_workflow.gen.approval", [
        inspect(Expense),
        "--approver",
        inspect(User),
        "--overdue-after",
        "2d"
      ])

    assert second.changed == %{}
  end

  describe "CanRequest" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Expense), "--approver", inspect(User)]
        |> generate()
        |> allow_approvers()
        |> compile(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} =
               recipe.modules[ExpenseApproval]
               |> Ash.Changeset.for_create(:request, %{subject_id: expense(recipe).id},
                 actor: user(recipe, :employee)
               )
               |> Ash.create()

      assert Ash.read!(recipe.modules[ExpenseApproval], authorize?: false) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can open or approve a request yet")
             )
    end
  end

  describe "CanApprove" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Expense), "--approver", inspect(User)]
        |> generate()
        |> allow_requesters()
        |> compile(tmp_dir)

      approval = request(recipe, expense(recipe), user(recipe, :employee))

      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :approve, user(recipe))
      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :reject, user(recipe))
      assert state(approval) == :pending
    end

    test "lets an approver decide once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir)
      approval = request(recipe, expense(recipe), user(recipe, :employee))

      assert {:error, %Ash.Error.Forbidden{}} =
               decide(approval, :approve, user(recipe, :employee))

      assert {:ok, %{state: :approved}} = decide(approval, :approve, user(recipe))
    end
  end

  describe "the shared approval rules" do
    test "the requester cannot decide their own request", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir)
      requester = user(recipe)
      approval = request(recipe, expense(recipe), requester)

      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :approve, requester)
      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :reject, requester)
    end

    test "an approver cannot decide twice", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir, ["--required-approvals", "2"])
      approver = user(recipe)
      approval = request(recipe, expense(recipe), user(recipe, :employee))

      assert {:ok, approval} = decide(approval, :approve, approver)
      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :approve, approver)
      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :reject, approver)

      # Past the policy, the decision's :unique_approver identity still refuses it.
      assert {:error, %Ash.Error.Invalid{errors: [identity_error]}} =
               approval
               |> Ash.Changeset.for_update(:reject, %{}, actor: approver, authorize?: false)
               |> Ash.update()

      assert %Ash.Error.Changes.InvalidChanges{
               fields: [:approval_id, :approver_id],
               message: "has already been taken"
             } = identity_error
    end

    test "only the requester can cancel", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir)
      requester = user(recipe, :employee)
      approval = request(recipe, expense(recipe), requester)

      assert {:error, %Ash.Error.Forbidden{}} = decide(approval, :cancel, user(recipe))
      assert {:ok, %{state: :cancelled}} = decide(approval, :cancel, requester)
    end
  end

  describe "the quorum" do
    test "loops back until the required approvals are met", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir, ["--required-approvals", "2"])
      approval = request(recipe, expense(recipe), user(recipe, :employee))

      assert approval.required_approvals == 2
      assert {:ok, %{state: :pending} = approval} = decide(approval, :approve, user(recipe))
      assert {:ok, %{state: :approved}} = decide(approval, :approve, user(recipe))
    end

    test "cannot be lowered by the requester", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir, ["--required-approvals", "2"])
      input = %{subject_id: expense(recipe).id, required_approvals: 1}

      assert {:error, %Ash.Error.Invalid{errors: [%NoSuchInput{input: :required_approvals}]}} =
               recipe.modules[ExpenseApproval]
               |> Ash.Changeset.for_create(:request, input, actor: user(recipe, :employee))
               |> Ash.create()
    end

    test "one rejection rejects the request", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir, ["--required-approvals", "2"])
      approval = request(recipe, expense(recipe), user(recipe, :employee))

      assert {:ok, approval} = decide(approval, :approve, user(recipe))
      assert {:ok, %{state: :rejected}} = decide(approval, :reject, user(recipe))
    end
  end

  describe "--overdue-after" do
    test "moves a request nobody has decided to overdue once the deadline passes", %{
      tmp_dir: tmp_dir
    } do
      recipe = approval_for_expenses(tmp_dir, ["--overdue-after", "2d"])
      approval_module = recipe.modules[ExpenseApproval]
      expense = expense(recipe)

      fresh = request(recipe, expense, user(recipe, :employee))
      late = requested_days_ago(recipe, expense, user(recipe, :employee), 3)

      assert Timeline.run_due(approval_module) == 1
      assert state(fresh) == :pending
      assert state(late) == :overdue

      late = Ash.get!(approval_module, late.id)
      assert {:ok, %{state: :approved}} = decide(late, :approve, user(recipe))
    end

    test "a partial approval does not restart the overdue clock", %{tmp_dir: tmp_dir} do
      recipe =
        approval_for_expenses(tmp_dir, ["--overdue-after", "2d", "--required-approvals", "2"])

      approval = requested_days_ago(recipe, expense(recipe), user(recipe, :employee), 3)

      assert {:ok, %{state: :pending} = approval} = decide(approval, :approve, user(recipe))

      assert Timeline.run_due(recipe.modules[ExpenseApproval]) == 1
      assert state(approval) == :overdue

      overdue = Ash.get!(recipe.modules[ExpenseApproval], approval.id)
      assert {:ok, %{state: :approved}} = decide(overdue, :approve, user(recipe))
    end

    test "without it, no overdue step is generated", %{tmp_dir: tmp_dir} do
      recipe = approval_for_expenses(tmp_dir)
      approval_module = recipe.modules[ExpenseApproval]

      assert step_names(approval_module) == [:pending, :approved, :rejected, :cancelled]
      assert AshWorkflow.Info.scheduled_work(approval_module) == []
    end

    for {flag, duration} <- [
          {"30m", {30, :minutes}},
          {"12h", {12, :hours}},
          {"2d", {2, :days}},
          {"2w", {14, :days}}
        ] do
      test "parses #{flag} as #{inspect(duration)}", %{tmp_dir: tmp_dir} do
        recipe = approval_for_expenses(tmp_dir, ["--overdue-after", unquote(flag)])

        assert [%{fire_after: unquote(Macro.escape(duration)), field: :requested_at}] =
                 recipe.modules[ExpenseApproval]
                 |> AshWorkflow.Info.steps()
                 |> Enum.flat_map(& &1.timeouts)
      end
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.approval", [
          inspect(Expense),
          "--approver",
          inspect(User),
          "--overdue-after",
          "2y"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--overdue-after must look like"))
    end
  end

  test "generates Postgres-backed resources on the subject's repo", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([
        "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket",
        "--approver",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketApproval: "postgres_ticket_approvals",
          PostgresTicketApprovalDecision: "postgres_ticket_approval_decisions",
          PostgresTicketApprovalTransition: "postgres_ticket_approvals_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  describe "locking a decided request" do
    test "on Postgres, locks the row before :approve routes and before :reject", %{
      tmp_dir: tmp_dir
    } do
      recipe =
        [
          "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
          "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
        ]
        |> generate([
          "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket",
          "--approver",
          "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer",
          "--no-transition-log"
        ])
        |> compile(tmp_dir)

      approval =
        recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicketApproval]

      lock_then_route = [
        Ash.Resource.Change.GetAndLockForUpdate,
        AshWorkflow.Changes.ConditionalTransition
      ]

      assert approval |> change_modules(:approve) |> Enum.filter(&(&1 in lock_then_route)) ==
               lock_then_route

      assert Ash.Resource.Change.GetAndLockForUpdate in change_modules(approval, :reject)
    end

    test "on ETS, takes no lock", %{tmp_dir: tmp_dir} do
      approval = approval_for_expenses(tmp_dir).modules[ExpenseApproval]

      for action <- [:approve, :reject] do
        refute Ash.Resource.Change.GetAndLockForUpdate in change_modules(approval, action)
      end
    end
  end

  defp change_modules(resource, action) do
    for %{change: {module, _opts}} <- Ash.Resource.Info.action(resource, action).changes,
        do: module
  end

  test "shortens a Postgres identity index name past 63 bytes", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([
        "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket",
        "--approver",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer",
        "--module",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.RegionalFinanceManagerSignOff",
        "--no-transition-log"
      ])
      |> compile(tmp_dir)

    decision =
      recipe.modules[
        AshWorkflowTest.RecipeFixtures.TransitionLog.RegionalFinanceManagerSignOffDecision
      ]

    assert [unique_approver: name] = AshPostgres.DataLayer.Info.identity_index_names(decision)
    assert byte_size(name) == 63
  end

  describe "the modules written" do
    @approval_dir "lib/ash_workflow_test/recipe_fixtures/approval"
    @modules [
      "#{@approval_dir}/expense_approval.ex",
      "#{@approval_dir}/expense_approval_decision.ex",
      "#{@approval_dir}/expense_approval/changes/record_decision.ex",
      "#{@approval_dir}/expense_approval/checks/can_request.ex",
      "#{@approval_dir}/expense_approval/checks/can_approve.ex"
    ]

    test "are six with the default transition log" do
      recipe = generate([inspect(Expense), "--approver", inspect(User)])

      assert Enum.sort(Map.keys(recipe.changed) -- @files) ==
               Enum.sort(["#{@approval_dir}/expense_approval_transition.ex" | @modules])
    end

    test "are five with --no-transition-log" do
      recipe = generate([inspect(Expense), "--approver", inspect(User), "--no-transition-log"])

      assert Enum.sort(Map.keys(recipe.changed) -- @files) == Enum.sort(@modules)
    end
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @domain_files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.approval", [
        inspect(Invoice),
        "--approver",
        inspect(User)
      ])

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Pass --domain to create it"))
  end

  describe "foreign keys" do
    test "take the type of the subject's and approver's primary keys", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Receipt), "--approver", inspect(User)]
        |> generate()
        |> allow_requesters(
          "lib/ash_workflow_test/recipe_fixtures/approval/receipt_approval/checks"
        )
        |> compile(tmp_dir)

      approval = recipe.modules[AshWorkflowTest.RecipeFixtures.Approval.ReceiptApproval]
      decision = recipe.modules[AshWorkflowTest.RecipeFixtures.Approval.ReceiptApprovalDecision]

      assert Ash.Resource.Info.attribute(approval, :subject_id).type == Ash.Type.Integer
      assert Ash.Resource.Info.attribute(approval, :requested_by_id).type == Ash.Type.UUIDv7
      assert Ash.Resource.Info.attribute(decision, :approver_id).type == Ash.Type.UUIDv7

      receipt =
        recipe.modules[Receipt]
        |> Ash.Changeset.for_create(:create, %{id: 7, merchant: "Cab Co"})
        |> Ash.create!()

      request =
        approval
        |> Ash.Changeset.for_create(:request, %{subject_id: receipt.id},
          actor: user(recipe, :employee)
        )
        |> Ash.create!()

      assert Ash.load!(receipt, latest_approval: :id).latest_approval.id == request.id
    end

    test "report an issue for a subject with a composite primary key" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.approval", [
          inspect(LedgerLine),
          "--approver",
          inspect(User)
        ])

      assert Enum.any?(
               igniter.issues,
               &(&1 =~ "#{inspect(LedgerLine)} has a composite primary key")
             )
    end

    test "report an issue for an approver with a composite primary key" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.approval", [
          inspect(Expense),
          "--approver",
          inspect(LedgerLine)
        ])

      assert Enum.any?(
               igniter.issues,
               &(&1 =~ "#{inspect(LedgerLine)} has a composite primary key")
             )
    end
  end

  defp names(entities), do: Enum.map(entities, & &1.name)

  # Spark metadata records the file each entity was compiled from, which
  # differs between the fixture and the generated copy.
  defp attributes(resource) do
    resource |> Ash.Resource.Info.attributes() |> Enum.map(&Map.delete(&1, :__spark_metadata__))
  end

  defp actions(resource) do
    for action <- Ash.Resource.Info.actions(resource) do
      changes = action |> Map.get(:changes, []) |> Enum.map(& &1.change)
      {action.name, action.type, Map.get(action, :accept), changes, names(action.arguments)}
    end
  end
end
