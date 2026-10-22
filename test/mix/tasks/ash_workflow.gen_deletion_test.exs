defmodule Mix.Tasks.AshWorkflow.Gen.DeletionTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Deletion.Account
  alias AshWorkflowTest.RecipeFixtures.Deletion.AccountDeletion
  alias AshWorkflowTest.RecipeFixtures.Deletion.AccountDeletion.Changes.Purge
  alias AshWorkflowTest.RecipeFixtures.Deletion.AccountDeletionTransition
  alias AshWorkflowTest.RecipeFixtures.Deletion.Domain
  alias AshWorkflowTest.RecipeFixtures.Deletion.Workspace

  @fixtures "test/support/recipe_fixtures/deletion"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/account.ex"]
  @checks "lib/ash_workflow_test/recipe_fixtures/deletion/account_deletion/checks"
  @can_request "#{@checks}/can_request.ex"
  @can_restore "#{@checks}/can_restore.ex"
  @purge "lib/ash_workflow_test/recipe_fixtures/deletion/account_deletion/changes/purge.ex"
  @owner %{id: "owner", role: :owner}
  @deny "def match?(_actor, _context, _opts), do: false"

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.deletion", argv)
  end

  defp deletion_for_accounts(tmp_dir, argv \\ []) do
    [inspect(Account), "--grace-period", "30d" | argv]
    |> generate()
    |> allow_owners()
    |> fill_purge()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in both
  # checks. Here an actor with the :owner role may request and restore.
  defp allow_owners(recipe) do
    Enum.reduce([@can_request, @can_restore], recipe, fn path, recipe ->
      edit_source(recipe, path, fn source ->
        String.replace(
          source,
          @deny,
          "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :owner"
        )
      end)
    end)
  end

  # What an application does once it has generated the recipe: define what a
  # purge erases. Here it erases nothing and succeeds.
  defp fill_purge(recipe) do
    edit_source(recipe, @purge, fn source ->
      Regex.replace(
        ~r/def change\(changeset, _opts, _context\) do\n.*?\n  end/s,
        source,
        "def change(changeset, _opts, _context), do: changeset"
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
    |> Ash.Changeset.for_create(:create, %{name: "Ada"})
    |> Ash.create!()
  end

  defp request(recipe, subject, opts \\ []) do
    {requested_at, opts} = Keyword.pop(opts, :requested_at)

    recipe.modules[AccountDeletion]
    |> Ash.Changeset.for_create(
      :request,
      %{subject_id: subject.id},
      Keyword.put_new(opts, :actor, @owner)
    )
    |> then(fn changeset ->
      if requested_at,
        do: Ash.Changeset.force_change_attribute(changeset, :requested_at, requested_at),
        else: changeset
    end)
    |> Ash.create()
  end

  defp lapsed(recipe, subject, opts \\ []) do
    {:ok, deletion} = request(recipe, subject, [requested_at: days_ago(31)] ++ opts)
    deletion
  end

  defp transition(deletion, action, actor \\ @owner) do
    deletion
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp reload(deletion), do: Ash.get!(deletion.__struct__, deletion.id)

  defp run_until_settled(resource, runs \\ 0) do
    case Timeline.run_due(resource) do
      0 -> runs
      _count -> run_until_settled(resource, runs + 1)
    end
  end

  defp purge_work(resource) do
    resource
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.find(&(&1.step == :purging && !&1.timeout))
  end

  defp log(recipe) do
    recipe.modules[AccountDeletionTransition] |> Ash.read!() |> Enum.map(& &1.to_state)
  end

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the deletion edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = deletion_for_accounts(tmp_dir)
      subject = recipe.modules[Account]

      assert attributes(subject) == attributes(Account)
      assert actions(subject) == actions(Account)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Account)) == [:deletion]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Account)) == [:pending_deletion?]
    end

    test "is pending deletion from the request until the purge succeeds", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      account = account(recipe)
      pending? = fn -> Ash.load!(account, :pending_deletion?).pending_deletion? end

      refute pending?.()

      lapsed(recipe, account)
      assert pending?.()

      assert Timeline.run_due(recipe.modules[AccountDeletion]) == 1
      assert pending?.()

      run_until_settled(recipe.modules[AccountDeletion])
      refute pending?.()
    end
  end

  test "creates a missing subject in the given domain and deletes against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @files
      |> generate([inspect(Workspace), "--grace-period", "7d", "--domain", inspect(Domain)])
      |> compile(tmp_dir)

    workspace_module = recipe.modules[Workspace]
    deletion_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Deletion.WorkspaceDeletion]

    assert Ash.Resource.Info.data_layer(workspace_module) == Ash.DataLayer.Ets
    assert workspace_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    workspace = workspace_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    deletion =
      deletion_module
      |> Ash.Changeset.for_create(:request, %{subject_id: workspace.id}, authorize?: false)
      |> Ash.create!()

    assert deletion.state == :requested
    assert Ash.load!(workspace, deletion: :id).deletion.id == deletion.id
    assert Ash.Resource.Info.attribute(deletion_module, :subject_id).type == Ash.Type.UUIDv7
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Account), "--grace-period", "30d"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.deletion", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  test "a subject has at most one deletion", %{tmp_dir: tmp_dir} do
    recipe = deletion_for_accounts(tmp_dir)
    account = account(recipe)

    assert {:ok, _deletion} = request(recipe, account)
    assert {:error, %Ash.Error.Invalid{}} = request(recipe, account)
  end

  describe "CanRequest" do
    test "refuses every request as generated, including one with no actor", %{
      tmp_dir: tmp_dir
    } do
      recipe =
        [inspect(Account), "--grace-period", "30d"]
        |> generate()
        |> compile(tmp_dir)

      account = account(recipe)

      assert {:error, %Ash.Error.Forbidden{}} = request(recipe, account)
      assert {:error, %Ash.Error.Forbidden{}} = request(recipe, account, actor: nil)
      assert Ash.read!(recipe.modules[AccountDeletion]) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can request or restore a deletion yet")
             )
    end

    test "refuses request_again as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Account), "--grace-period", "30d"]
        |> generate()
        |> compile(tmp_dir)

      {:ok, deletion} = request(recipe, account(recipe), authorize?: false)

      {:ok, restored} =
        deletion
        |> Ash.Changeset.for_update(:restore, %{}, authorize?: false)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} = transition(restored, :request_again)
      assert reload(restored).state == :restored
    end

    test "lets an owner request once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      account = account(recipe)

      assert {:error, %Ash.Error.Forbidden{}} = request(recipe, account, actor: nil)

      assert {:error, %Ash.Error.Forbidden{}} =
               request(recipe, account, actor: %{id: "other", role: :member})

      assert {:ok, %{state: :requested}} = request(recipe, account)
    end

    test "lets an owner request again once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      {:ok, deletion} = request(recipe, account(recipe))
      {:ok, restored} = transition(deletion, :restore)

      assert {:error, %Ash.Error.Forbidden{}} =
               transition(restored, :request_again, %{id: "other", role: :member})

      assert {:ok, %{state: :requested}} = transition(restored, :request_again)
    end

    test "leaves reads open to every actor", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      {:ok, deletion} = request(recipe, account(recipe))

      for actor <- [nil, %{id: "other", role: :member}] do
        assert [%{id: id}] = Ash.read!(recipe.modules[AccountDeletion], actor: actor)
        assert id == deletion.id
      end
    end
  end

  describe "CanRestore" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Account), "--grace-period", "30d"]
        |> generate()
        |> compile(tmp_dir)

      {:ok, deletion} = request(recipe, account(recipe), authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} = transition(deletion, :restore)
      assert reload(deletion).state == :requested
    end

    test "lets an owner restore once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      {:ok, deletion} = request(recipe, account(recipe))

      assert {:error, %Ash.Error.Forbidden{}} =
               transition(deletion, :restore, %{id: "other", role: :member})

      assert {:ok, %{state: :restored}} = transition(deletion, :restore)
    end
  end

  describe "the grace period" do
    test "moves a request to purging once it has passed since requested_at", %{
      tmp_dir: tmp_dir
    } do
      recipe = deletion_for_accounts(tmp_dir)
      deletion_module = recipe.modules[AccountDeletion]

      {:ok, recent} = request(recipe, account(recipe), requested_at: days_ago(29))
      lapsed = lapsed(recipe, account(recipe))

      assert Timeline.run_due(deletion_module) == 1
      assert reload(recent).state == :requested
      assert reload(lapsed).state == :purging
    end

    test "a restored request does not purge", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      {:ok, restored} = recipe |> lapsed(account(recipe)) |> transition(:restore)

      assert run_until_settled(recipe.modules[AccountDeletion]) == 0
      assert reload(restored).state == :restored
    end

    test "request_again starts a new grace period", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      deletion = lapsed(recipe, account(recipe))
      {:ok, restored} = transition(deletion, :restore)

      assert {:ok, requested} = transition(restored, :request_again)
      assert requested.state == :requested
      assert DateTime.after?(requested.requested_at, deletion.requested_at)

      assert Timeline.run_due(recipe.modules[AccountDeletion]) == 0
    end
  end

  describe "the purge" do
    test "a purge that succeeds moves the deletion to deleted", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir)
      deletion = lapsed(recipe, account(recipe))

      run_until_settled(recipe.modules[AccountDeletion])

      assert reload(deletion).state == :deleted
      assert Enum.sort(log(recipe)) == [:deleted, :purging, :requested]
    end

    test "an unfilled purge fails, is retried and then moves to purge_failed", %{
      tmp_dir: tmp_dir
    } do
      recipe =
        [inspect(Account), "--grace-period", "30d"]
        |> generate()
        |> allow_owners()
        |> compile(tmp_dir)

      deletion_module = recipe.modules[AccountDeletion]
      deletion = lapsed(recipe, account(recipe))

      # The grace-period timeout, then the purge's first attempt, which asks
      # for a retry and leaves the deletion in :purging.
      assert Timeline.run_due(deletion_module) == 1
      assert Timeline.run_due(deletion_module) == 1

      purging = reload(deletion)
      assert purging.state == :purging

      assert {:error, error} =
               purging
               |> Ash.Changeset.for_update(:purge, %{}, authorize?: false)
               |> Ash.update()

      assert Exception.message(error) =~
               "#{inspect(recipe.modules[Purge])} erases nothing yet. Replace its change/3"

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Every purge fails until you define")
             )

      work = purge_work(deletion_module)
      assert work.retry.max_attempts == 3
      assert {:retry, _delay_ms} = Scheduler.execute(work, purging, attempt: 2)
      assert reload(deletion).state == :purging

      assert {:ok, %{state: :purge_failed}} = Scheduler.execute(work, purging, attempt: 3)

      assert {:error, %Ash.Error.Forbidden{}} =
               transition(reload(deletion), :retry_purge, %{id: "other", role: :member})

      assert {:ok, %{state: :purging}} = transition(reload(deletion), :retry_purge)
    end

    test "--max-attempts sets how many times the purge runs", %{tmp_dir: tmp_dir} do
      recipe = deletion_for_accounts(tmp_dir, ["--max-attempts", "5"])

      assert purge_work(recipe.modules[AccountDeletion]).retry.max_attempts == 5
    end

    test "reports an issue for --max-attempts below 1" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.deletion", [
          inspect(Account),
          "--grace-period",
          "30d",
          "--max-attempts",
          "0"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--max-attempts must be at least 1"))
    end
  end

  test "generates every step whatever the options", %{tmp_dir: tmp_dir} do
    recipe = deletion_for_accounts(tmp_dir, ["--no-transition-log"])

    assert step_names(recipe.modules[AccountDeletion]) ==
             [:requested, :purging, :purge_failed, :restored, :deleted]
  end

  describe "--grace-period" do
    for {flag, duration} <- [
          {"30m", {30, :minutes}},
          {"12h", {12, :hours}},
          {"2d", {2, :days}},
          {"2w", {14, :days}}
        ] do
      test "parses #{flag} as a timeout anchored on requested_at", %{tmp_dir: tmp_dir} do
        recipe =
          [inspect(Account), "--grace-period", unquote(flag)]
          |> generate()
          |> compile(tmp_dir)

        [step] =
          recipe.modules[AccountDeletion]
          |> AshWorkflow.Info.steps()
          |> Enum.filter(&(&1.name == :requested))

        assert [%{fire_after: unquote(Macro.escape(duration)), field: :requested_at}] =
                 step.timeouts
      end
    end

    test "is required" do
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(
                   @files
                   |> project()
                   |> Igniter.compose_task("ash_workflow.gen.deletion", [inspect(Account)])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "Missing required flag grace-period"
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.deletion", [
          inspect(Account),
          "--grace-period",
          "2y"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--grace-period must look like"))
    end
  end

  test "generates a Postgres-backed resource on the subject's repo", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate([
        "AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket",
        "--grace-period",
        "7d"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketDeletion: "postgres_ticket_deletions",
          PostgresTicketDeletionTransition: "postgres_ticket_deletions_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Account), "--grace-period", "30d", "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.deletion", [
        inspect(Workspace),
        "--grace-period",
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
