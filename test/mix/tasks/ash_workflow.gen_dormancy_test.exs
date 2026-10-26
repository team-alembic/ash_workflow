defmodule Mix.Tasks.AshWorkflow.Gen.DormancyTest do
  use AshWorkflow.RecipeCase, async: true

  require Ash.Query

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Account
  alias AshWorkflowTest.RecipeFixtures.Dormancy.AccountDormancy
  alias AshWorkflowTest.RecipeFixtures.Dormancy.AccountDormancyTransition
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Domain
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Project

  @fixtures "test/support/recipe_fixtures/dormancy"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/account.ex"]
  @dormancy_source "lib/ash_workflow_test/recipe_fixtures/dormancy/account_dormancy.ex"
  @checks "lib/ash_workflow_test/recipe_fixtures/dormancy/account_dormancy/checks"
  @start_dormancy Module.concat(AccountDormancy, Changes.StartDormancy)
  @record_activity Module.concat(AccountDormancy, Changes.RecordActivity)
  @deny_all "def match?(_actor, _context, _opts), do: false"
  @argv ["--dormant-after", "30d", "--archive-after", "90d"]
  @support %{id: "support", role: :support}

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.dormancy", argv)
  end

  defp dormancy_for_accounts(tmp_dir, argv \\ @argv) do
    [inspect(Account) | argv]
    |> generate()
    |> allow_creators()
    |> allow_support()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanCreate and CanReactivate. Here any actor may create a dormancy, and
  # anyone with the :support role may reactivate.
  defp allow_creators(recipe) do
    edit_source(recipe, "#{@checks}/can_create.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_support(recipe) do
    edit_source(recipe, "#{@checks}/can_reactivate.ex", fn source ->
      String.replace(
        source,
        @deny_all,
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :support"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], &fun.(&1 || source!(recipe, path)))
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp account(recipe, name \\ "Acme") do
    recipe.modules[Account]
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  # Stands in for an account that existed before the task ran, which has no
  # dormancy.
  defp existing_account(recipe), do: Ash.Seed.seed!(recipe.modules[Account], %{name: "Old"})

  defp dormancy_of(recipe, account) do
    recipe.modules[AccountDormancy]
    |> Ash.Query.filter(subject_id == ^account.id)
    |> Ash.read!(authorize?: false)
  end

  # An account whose dormancy last saw activity some days ago.
  defp idle_dormancy(recipe, last_active_days_ago) do
    [dormancy] = dormancy_of(recipe, account(recipe))

    dormancy
    |> Ash.Changeset.for_update(:record_activity, %{})
    |> Ash.Changeset.force_change_attribute(:last_activity_at, days_ago(last_active_days_ago))
    |> Ash.update!()
  end

  defp create_dormancy(recipe, subject, actor \\ @support) do
    recipe.modules[AccountDormancy]
    |> Ash.Changeset.for_create(:create, %{subject_id: subject.id}, actor: actor)
    |> Ash.create()
  end

  defp record_activity(dormancy) do
    dormancy
    |> Ash.Changeset.for_update(:record_activity, %{})
    |> Ash.update()
  end

  defp reactivate(dormancy, actor \\ @support) do
    dormancy
    |> Ash.Changeset.for_update(:reactivate, %{}, actor: actor)
    |> Ash.update()
  end

  # Nothing in the generated code writes state_entered_at except a transition,
  # so the test moves it back to stand in for a dormancy that went dormant
  # some days ago.
  defp dormant_since(dormancy, days) do
    dormancy
    |> Ash.Changeset.for_update(:record_activity, %{})
    |> Ash.Changeset.force_change_attribute(:state_entered_at, days_ago(days))
    |> Ash.update!()
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp reload(dormancy), do: Ash.get!(dormancy.__struct__, dormancy.id)

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  # What an application does to count every update of an account as activity.
  defp record_activity_on_update(tmp_dir) do
    [inspect(Account) | @argv]
    |> generate()
    |> edit_source("#{@fixtures}/account.ex", fn source ->
      String.replace(
        source,
        "  changes do\n",
        "  changes do\n    change(#{inspect(@record_activity)}, on: [:update])\n"
      )
    end)
    |> compile(tmp_dir)
  end

  defp rename(account) do
    account
    |> Ash.Changeset.for_update(:rename, %{name: "Renamed"})
    |> Ash.update()
  end

  defp notice?(recipe, text), do: Enum.any?(recipe.notices, &String.contains?(&1, text))

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the dormancy edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = dormancy_for_accounts(tmp_dir)
      subject = recipe.modules[Account]

      assert attributes(subject) == attributes(Account)
      assert actions(subject) == actions(Account)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Account)) == [:dormancy]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Account)) == [:dormant?]

      assert global_changes(subject) == [
               {{recipe.modules[@start_dormancy], []}, [:create]}
             ]
    end

    for argv <- [["--dormant-after", "30d"], ["--dormant-after", "30d", "--archive-after", "90d"]] do
      test "is not dormant without a dormancy for #{Enum.join(argv, " ")}", %{tmp_dir: tmp_dir} do
        recipe = dormancy_for_accounts(tmp_dir, unquote(argv))

        assert Ash.load!(existing_account(recipe), :dormant?).dormant? == false
      end
    end

    test "is dormant while its dormancy is dormant or archived", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]
      dormancy = idle_dormancy(recipe, 31)
      account = Ash.get!(recipe.modules[Account], dormancy.subject_id)

      refute Ash.load!(account, :dormant?).dormant?

      assert Timeline.run_due(dormancy_module) == 1
      assert Ash.load!(account, :dormant?).dormant?

      dormancy |> reload() |> dormant_since(91)
      assert Timeline.run_due(dormancy_module) == 1
      assert reload(dormancy).state == :archived
      assert Ash.load!(account, :dormant?).dormant?

      {:ok, _active} = dormancy |> reload() |> reactivate()
      refute Ash.load!(account, :dormant?).dormant?
    end

    test "keeps the entries of a changes block it already has", %{tmp_dir: tmp_dir} do
      recipe =
        project_with_account(fn source ->
          String.replace(
            source,
            "  attributes do\n",
            "  changes do\n    change set_attribute(:renamed?, true), on: [:create]\n  end\n\n" <>
              "  attributes do\n"
          )
        end)
        |> run_task("ash_workflow.gen.dormancy", [inspect(Account) | @argv])

      source = source!(recipe, "#{@fixtures}/account.ex")

      assert [_before, block] = String.split(source, "changes do")
      assert block =~ ~r/\A\s+change\(set_attribute\(:renamed\?, true\), on: \[:create\]\)\n\n/
      assert block =~ "StartDormancy"

      recipe = compile(recipe, tmp_dir)
      account = account(recipe)

      assert account.renamed?
      assert [%{state: :active}] = dormancy_of(recipe, account)
    end
  end

  describe "StartDormancy" do
    test "gives a new subject an active dormancy that starts now", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      account = account(recipe)

      assert [%{state: :active} = dormancy] = dormancy_of(recipe, account)
      assert DateTime.diff(DateTime.utc_now(), dormancy.last_activity_at, :second) < 5
      refute Ash.load!(account, :dormant?).dormant?
    end

    test "gives each subject of a bulk create its own dormancy", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)

      assert %Ash.BulkResult{status: :success, records: accounts} =
               Ash.bulk_create(
                 [%{name: "One"}, %{name: "Two"}, %{name: "Three"}],
                 recipe.modules[Account],
                 :create,
                 return_records?: true,
                 return_errors?: true
               )

      for account <- accounts do
        assert [%{state: :active}] = dormancy_of(recipe, account)
      end

      assert length(Ash.read!(recipe.modules[AccountDormancy], authorize?: false)) == 3
    end

    test "gives a bulk create that returns no records a dormancy per subject", %{
      tmp_dir: tmp_dir
    } do
      recipe = dormancy_for_accounts(tmp_dir)

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create(
                 [%{name: "One"}, %{name: "Two"}],
                 recipe.modules[Account],
                 :create,
                 return_errors?: true
               )

      assert length(Ash.read!(recipe.modules[AccountDormancy], authorize?: false)) == 2
    end

    test "creates no second dormancy when a create upserts onto an existing subject", %{
      tmp_dir: tmp_dir
    } do
      recipe = dormancy_for_accounts(tmp_dir)
      account = account(recipe)
      [dormancy] = dormancy_of(recipe, account)

      assert {:ok, upserted} =
               recipe.modules[Account]
               |> Ash.Changeset.for_create(:create, %{name: "Renamed"})
               |> Ash.Changeset.force_change_attribute(:id, account.id)
               |> Ash.create(upsert?: true)

      assert upserted.__metadata__.upsert_action == :update
      assert dormancy_of(recipe, account) == [dormancy]
    end

    test "starts a dormancy while CanCreate still denies everyone", %{tmp_dir: tmp_dir} do
      recipe = [inspect(Account) | @argv] |> generate() |> compile(tmp_dir)
      account = account(recipe)

      assert [%{state: :active}] = dormancy_of(recipe, account)
    end

    test "the dormant timeout fires for the dormancy it started", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      account = account(recipe)
      [dormancy] = dormancy_of(recipe, account)

      assert Timeline.run_due(recipe.modules[AccountDormancy]) == 0

      dormancy
      |> Ash.Changeset.for_update(:record_activity, %{})
      |> Ash.Changeset.force_change_attribute(:last_activity_at, days_ago(31))
      |> Ash.update!()

      assert Timeline.run_due(recipe.modules[AccountDormancy]) == 1
      assert reload(dormancy).state == :dormant
      assert Ash.load!(account, :dormant?).dormant?
    end

    test "fails the subject create when the dormancy cannot be created", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Account) | @argv]
        |> generate()
        |> edit_source(@dormancy_source, fn source ->
          Regex.replace(
            ~r/accept\(?\[:subject_id, :last_activity_at\]\)?\n/,
            source,
            "\\0      validate(absent(:subject_id))\n"
          )
        end)
        |> compile(tmp_dir)

      assert {:error, %Ash.Error.Invalid{}} =
               recipe.modules[Account]
               |> Ash.Changeset.for_create(:create, %{name: "Acme"})
               |> Ash.create()
    end
  end

  describe "RecordActivity" do
    test "is generated but not added to the subject" do
      recipe = generate([inspect(Account) | @argv])

      assert Map.has_key?(
               recipe.changed,
               "lib/ash_workflow_test/recipe_fixtures/dormancy/account_dormancy/changes/record_activity.ex"
             )

      refute source!(recipe, "#{@fixtures}/account.ex") =~ "RecordActivity"
      assert notice?(recipe, "change #{inspect(@record_activity)}, on: [:update]")
    end

    test "moves last_activity_at when added to the subject's updates", %{tmp_dir: tmp_dir} do
      recipe = record_activity_on_update(tmp_dir)
      dormancy = idle_dormancy(recipe, 31)
      account = Ash.get!(recipe.modules[Account], dormancy.subject_id)

      assert {:ok, %{renamed?: true}} = rename(account)

      assert DateTime.diff(DateTime.utc_now(), reload(dormancy).last_activity_at, :second) < 5
      assert Timeline.run_due(recipe.modules[AccountDormancy]) == 0
      assert reload(dormancy).state == :active
    end

    test "does nothing for a subject with no dormancy", %{tmp_dir: tmp_dir} do
      recipe = record_activity_on_update(tmp_dir)
      account = existing_account(recipe)

      assert {:ok, %{renamed?: true}} = rename(account)
      assert dormancy_of(recipe, account) == []
    end
  end

  test "creates a missing subject in the given domain and tracks it", %{tmp_dir: tmp_dir} do
    recipe =
      generate([inspect(Project), "--domain", inspect(Domain), "--dormant-after", "30d"])
      |> compile(tmp_dir)

    project_module = recipe.modules[Project]
    dormancy_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Dormancy.ProjectDormancy]

    assert Ash.Resource.Info.data_layer(project_module) == Ash.DataLayer.Ets
    assert project_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    project = project_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    assert [%{state: :active} = dormancy] = Ash.read!(dormancy_module, authorize?: false)
    assert Ash.load!(project, dormancy: :id).dormancy.id == dormancy.id
  end

  describe "running the task a second time" do
    test "changes nothing" do
      argv = [inspect(Account) | @argv]
      first = generate(argv)
      second = run_task(first.igniter, "ash_workflow.gen.dormancy", argv)

      assert second.changed == %{}
      assert second.warnings == []
    end

    test "warns about a StartDormancy change that differs from the recipe's" do
      argv = [inspect(Account) | @argv]
      first = generate(argv)

      edited =
        update_in(first.igniter.assigns.test_files["#{@fixtures}/account.ex"], fn source ->
          String.replace(source, "on: [:create]", "on: [:create, :update]")
        end)

      second = run_task(edited.igniter, "ash_workflow.gen.dormancy", argv)

      assert second.changed == %{}
      assert [warning] = second.warnings
      assert warning =~ "already has a change named #{inspect(@start_dormancy)}"
    end
  end

  test "a subject has at most one dormancy", %{tmp_dir: tmp_dir} do
    recipe = dormancy_for_accounts(tmp_dir)
    account = existing_account(recipe)

    assert {:ok, dormancy} = create_dormancy(recipe, account)
    assert DateTime.diff(DateTime.utc_now(), dormancy.last_activity_at, :second) < 5
    assert {:error, %Ash.Error.Invalid{}} = create_dormancy(recipe, account)
  end

  describe "CanCreate" do
    test "denies a direct create to everyone as generated", %{tmp_dir: tmp_dir} do
      recipe = [inspect(Account) | @argv] |> generate() |> allow_support() |> compile(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = create_dormancy(recipe, existing_account(recipe))
      assert Ash.read!(recipe.modules[AccountDormancy], authorize?: false) == []
      assert notice?(recipe, "Nobody can create a dormancy directly or reactivate one yet")
    end

    test "lets a creator create once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      account = existing_account(recipe)

      assert {:error, %Ash.Error.Forbidden{}} = create_dormancy(recipe, account, nil)
      assert {:ok, %{state: :active}} = create_dormancy(recipe, account)
    end
  end

  describe "CanReactivate" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe = [inspect(Account) | @argv] |> generate() |> allow_creators() |> compile(tmp_dir)
      dormancy = idle_dormancy(recipe, 31)

      Timeline.run_due(recipe.modules[AccountDormancy])

      assert {:error, %Ash.Error.Forbidden{}} = dormancy |> reload() |> reactivate()
      assert reload(dormancy).state == :dormant
      assert notice?(recipe, "Nobody can create a dormancy directly or reactivate one yet")
    end

    test "lets support reactivate once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy = idle_dormancy(recipe, 31)

      Timeline.run_due(recipe.modules[AccountDormancy])
      dormancy = reload(dormancy)

      assert {:error, %Ash.Error.Forbidden{}} =
               reactivate(dormancy, %{id: "other", role: :customer})

      assert {:ok, %{state: :active}} = reactivate(dormancy)
    end
  end

  describe "record_activity" do
    test "pushes the dormant deadline out", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]
      dormancy = idle_dormancy(recipe, 31)

      assert {:ok, %{state: :active}} = record_activity(dormancy)

      assert Timeline.run_due(dormancy_module) == 0
      assert reload(dormancy).state == :active
    end

    test "needs no actor and changes no state", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy = idle_dormancy(recipe, 31)

      Timeline.run_due(recipe.modules[AccountDormancy])

      assert {:ok, %{state: :dormant} = recorded} = dormancy |> reload() |> record_activity()
      assert DateTime.after?(recorded.last_activity_at, dormancy.last_activity_at)
    end
  end

  describe "the deadlines" do
    test "an inactive dormancy goes dormant and a recently active one stays active", %{
      tmp_dir: tmp_dir
    } do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]

      recent = idle_dormancy(recipe, 29)
      idle = idle_dormancy(recipe, 31)

      assert Timeline.run_due(dormancy_module) == 1
      assert reload(recent).state == :active
      assert reload(idle).state == :dormant
      assert Timeline.run_due(dormancy_module) == 0
    end

    test "a dormancy archives once it has been dormant for --archive-after", %{
      tmp_dir: tmp_dir
    } do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]

      lately = idle_dormancy(recipe, 200)
      long_ago = idle_dormancy(recipe, 200)

      assert Timeline.run_due(dormancy_module) == 2
      lately |> reload() |> dormant_since(89)
      long_ago |> reload() |> dormant_since(91)

      assert Timeline.run_due(dormancy_module) == 1
      assert reload(lately).state == :dormant
      assert reload(long_ago).state == :archived

      log = recipe.modules[AccountDormancyTransition] |> Ash.read!() |> Enum.map(& &1.to_state)
      assert Enum.frequencies(log) == %{active: 2, dormant: 2, archived: 1}
    end

    test "activity while dormant does not postpone archiving", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]
      dormancy = idle_dormancy(recipe, 200)

      Timeline.run_due(dormancy_module)
      dormancy |> reload() |> dormant_since(91)
      {:ok, _recorded} = dormancy |> reload() |> record_activity()

      assert Timeline.run_due(dormancy_module) == 1
      assert reload(dormancy).state == :archived
    end

    test "without --archive-after there is no archived step", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir, ["--dormant-after", "30d"])
      dormancy_module = recipe.modules[AccountDormancy]

      assert step_names(dormancy_module) == [:active, :dormant]

      dormancy = idle_dormancy(recipe, 31)
      assert Timeline.run_due(dormancy_module) == 1

      dormancy |> reload() |> dormant_since(10_000)
      assert Timeline.run_due(dormancy_module) == 0
      assert reload(dormancy).state == :dormant

      account = recipe.modules[Account] |> Ash.get!(dormancy.subject_id)
      assert Ash.load!(account, :dormant?).dormant?
    end
  end

  describe "reactivate" do
    for {state, runs} <- [dormant: 1, archived: 2] do
      test "returns a #{state} dormancy to active and resets last_activity_at", %{
        tmp_dir: tmp_dir
      } do
        recipe = dormancy_for_accounts(tmp_dir)
        dormancy_module = recipe.modules[AccountDormancy]
        dormancy = idle_dormancy(recipe, 200)

        Timeline.run_due(dormancy_module)
        if unquote(runs) == 2, do: dormancy |> reload() |> dormant_since(91)
        Timeline.run_due(dormancy_module)

        assert %{state: unquote(state)} = dormancy = reload(dormancy)
        assert {:ok, %{state: :active} = reactivated} = reactivate(dormancy)
        assert DateTime.diff(DateTime.utc_now(), reactivated.last_activity_at, :second) < 5

        assert Timeline.run_due(dormancy_module) == 0
        assert reload(dormancy).state == :active
      end
    end

    test "is not available while active", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      [dormancy] = dormancy_of(recipe, account(recipe))

      assert {:error, _error} = reactivate(dormancy)
    end
  end

  describe "options" do
    for {flag, duration} <- [
          {"1m", "{1, :minutes}"},
          {"30m", "{30, :minutes}"},
          {"12h", "{12, :hours}"},
          {"2w", "{14, :days}"}
        ] do
      test "parses --dormant-after #{flag} as #{duration}" do
        recipe = generate([inspect(Account), "--dormant-after", unquote(flag)])

        assert source!(recipe, @dormancy_source) =~ "fire_after: #{unquote(duration)}"
      end
    end

    for flag <- ["--dormant-after", "--archive-after"] do
      test "reports an issue for a #{flag} it cannot parse" do
        argv = [inspect(Account), "--dormant-after", "30d", unquote(flag), "2y"]
        igniter = @files |> project() |> Igniter.compose_task("ash_workflow.gen.dormancy", argv)

        assert Enum.any?(igniter.issues, &String.contains?(&1, "#{unquote(flag)} must look like"))
      end

      test "reports an issue for a sub-minute #{flag} under the default scheduler" do
        argv = [inspect(Account), "--dormant-after", "30d", unquote(flag), "10s"]
        igniter = @files |> project() |> Igniter.compose_task("ash_workflow.gen.dormancy", argv)

        assert Enum.any?(
                 igniter.issues,
                 &String.contains?(&1, "#{unquote(flag)} is shorter than")
               )
      end
    end
  end

  test "generates a Postgres-backed resource on the subject's repo", %{tmp_dir: tmp_dir} do
    namespace = AshWorkflowTest.RecipeFixtures.TransitionLog

    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([inspect(Module.concat(namespace, PostgresTicket)) | @argv])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketDormancy: "postgres_ticket_dormancies",
          PostgresTicketDormancyTransition: "postgres_ticket_dormancies_transitions"
        ] do
      resource = recipe.modules[Module.concat(namespace, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end

    start_dormancy = Module.concat(namespace, PostgresTicketDormancy.Changes.StartDormancy)

    assert {{recipe.modules[start_dormancy], []}, [:create]} in global_changes(
             recipe.modules[Module.concat(namespace, PostgresTicket)]
           )
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Account), "--dormant-after", "30d", "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.dormancy", [
        inspect(Project),
        "--dormant-after",
        "30d"
      ])

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Pass --domain to create it"))
  end

  defp project_with_account(fun) do
    account = "#{@fixtures}/account.ex"

    files =
      Map.new(@files, fn path ->
        source = File.read!(path)
        {path, if(path == account, do: fun.(source), else: source)}
      end)

    Igniter.Test.test_project(app_name: :ash_workflow, files: files)
  end

  defp names(entities), do: Enum.map(entities, & &1.name)

  defp global_changes(resource) do
    for %Ash.Resource.Change{} = change <- Ash.Resource.Info.changes(resource),
        do: {change.change, change.on}
  end

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
