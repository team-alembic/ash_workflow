defmodule Mix.Tasks.AshWorkflow.Gen.DormancyTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Account
  alias AshWorkflowTest.RecipeFixtures.Dormancy.AccountDormancy
  alias AshWorkflowTest.RecipeFixtures.Dormancy.AccountDormancyTransition
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Domain
  alias AshWorkflowTest.RecipeFixtures.Dormancy.Project

  @fixtures "test/support/recipe_fixtures/dormancy"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/account.ex"]
  @checks "lib/ash_workflow_test/recipe_fixtures/dormancy/account_dormancy/checks"
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
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp account(recipe) do
    recipe.modules[Account]
    |> Ash.Changeset.for_create(:create, %{name: "Acme"})
    |> Ash.create!()
  end

  defp track(recipe, subject, last_active_days_ago \\ 0, actor \\ @support) do
    recipe.modules[AccountDormancy]
    |> Ash.Changeset.for_create(
      :create,
      %{subject_id: subject.id, last_activity_at: days_ago(last_active_days_ago)},
      actor: actor
    )
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
    end

    for argv <- [["--dormant-after", "30d"], ["--dormant-after", "30d", "--archive-after", "90d"]] do
      test "is not dormant without a dormancy for #{Enum.join(argv, " ")}", %{tmp_dir: tmp_dir} do
        recipe = dormancy_for_accounts(tmp_dir, unquote(argv))

        assert Ash.load!(account(recipe), :dormant?).dormant? == false
      end
    end

    test "is dormant while its dormancy is dormant or archived", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      dormancy_module = recipe.modules[AccountDormancy]
      account = account(recipe)

      {:ok, dormancy} = track(recipe, account, 31)
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

    dormancy =
      dormancy_module
      |> Ash.Changeset.for_create(:create, %{subject_id: project.id})
      |> Ash.create!(authorize?: false)

    assert dormancy.state == :active
    assert Ash.load!(project, dormancy: :id).dormancy.id == dormancy.id
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Account) | @argv]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.dormancy", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  test "a subject has at most one dormancy", %{tmp_dir: tmp_dir} do
    recipe = dormancy_for_accounts(tmp_dir)
    account = account(recipe)

    assert {:ok, dormancy} = track(recipe, account)
    assert DateTime.diff(DateTime.utc_now(), dormancy.last_activity_at, :second) < 5
    assert {:error, %Ash.Error.Invalid{}} = track(recipe, account)
  end

  describe "CanCreate" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe = [inspect(Account) | @argv] |> generate() |> allow_support() |> compile(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = track(recipe, account(recipe))
      assert Ash.read!(recipe.modules[AccountDormancy]) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can create or reactivate a dormancy yet")
             )
    end

    test "lets a creator create once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      account = account(recipe)

      assert {:error, %Ash.Error.Forbidden{}} = track(recipe, account, 0, nil)
      assert {:ok, %{state: :active}} = track(recipe, account)
    end
  end

  describe "CanReactivate" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe = [inspect(Account) | @argv] |> generate() |> allow_creators() |> compile(tmp_dir)
      {:ok, dormancy} = track(recipe, account(recipe), 31)

      Timeline.run_due(recipe.modules[AccountDormancy])

      assert {:error, %Ash.Error.Forbidden{}} = dormancy |> reload() |> reactivate()
      assert reload(dormancy).state == :dormant

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can create or reactivate a dormancy yet")
             )
    end

    test "lets support reactivate once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      {:ok, dormancy} = track(recipe, account(recipe), 31)

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
      {:ok, dormancy} = track(recipe, account(recipe), 31)

      assert {:ok, %{state: :active}} = record_activity(dormancy)

      assert Timeline.run_due(dormancy_module) == 0
      assert reload(dormancy).state == :active
    end

    test "needs no actor and changes no state", %{tmp_dir: tmp_dir} do
      recipe = dormancy_for_accounts(tmp_dir)
      {:ok, dormancy} = track(recipe, account(recipe), 31)

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

      {:ok, recent} = track(recipe, account(recipe), 29)
      {:ok, idle} = track(recipe, account(recipe), 31)

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

      {:ok, lately} = track(recipe, account(recipe), 200)
      {:ok, long_ago} = track(recipe, account(recipe), 200)

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
      {:ok, dormancy} = track(recipe, account(recipe), 200)

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

      {:ok, dormancy} = track(recipe, account(recipe), 31)
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
        {:ok, dormancy} = track(recipe, account(recipe), 200)

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
      {:ok, dormancy} = track(recipe, account(recipe))

      assert {:error, _error} = reactivate(dormancy)
    end
  end

  describe "options" do
    for {flag, duration} <- [
          {"10s", "{10, :seconds}"},
          {"30m", "{30, :minutes}"},
          {"12h", "{12, :hours}"},
          {"2w", "{14, :days}"}
        ] do
      test "parses --dormant-after #{flag} as #{duration}" do
        recipe = generate([inspect(Account), "--dormant-after", unquote(flag)])

        assert source!(
                 recipe,
                 "lib/ash_workflow_test/recipe_fixtures/dormancy/account_dormancy.ex"
               ) =~
                 "fire_after: #{unquote(duration)}"
      end
    end

    for flag <- ["--dormant-after", "--archive-after"] do
      test "reports an issue for a #{flag} it cannot parse" do
        argv = [inspect(Account), "--dormant-after", "30d", unquote(flag), "2y"]
        igniter = @files |> project() |> Igniter.compose_task("ash_workflow.gen.dormancy", argv)

        assert Enum.any?(igniter.issues, &String.contains?(&1, "#{unquote(flag)} must look like"))
      end
    end
  end

  test "generates a Postgres-backed resource on the subject's repo", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([
        "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket" | @argv
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketDormancy: "postgres_ticket_dormancies",
          PostgresTicketDormancyTransition: "postgres_ticket_dormancies_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
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
