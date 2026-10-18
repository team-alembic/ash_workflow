defmodule Mix.Tasks.AshWorkflow.Gen.SyncTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Sync.Account
  alias AshWorkflowTest.RecipeFixtures.Sync.Customer
  alias AshWorkflowTest.RecipeFixtures.Sync.CustomerSync
  alias AshWorkflowTest.RecipeFixtures.Sync.CustomerSyncTransition
  alias AshWorkflowTest.RecipeFixtures.Sync.Domain
  alias AshWorkflowTest.RecipeFixtures.Sync.FakePush

  @fixtures "test/support/recipe_fixtures/sync"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/customer.ex"]
  @sync_file "lib/ash_workflow_test/recipe_fixtures/sync/customer_sync.ex"
  @can_resync "lib/ash_workflow_test/recipe_fixtures/sync/customer_sync/checks/can_resync.ex"
  @operator %{id: "operator", role: :operator}

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.sync", argv)
  end

  defp sync_for_customers(tmp_dir, argv \\ ["--max-attempts", "3", "--backoff", "30s"]) do
    [inspect(Customer) | argv]
    |> generate()
    |> fill_in_push()
    |> allow_operators()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: add the change
  # that calls the external system to :push.
  defp fill_in_push(recipe) do
    edit_source(recipe, @sync_file, fn source ->
      String.replace(
        source,
        "change(set_attribute(:last_synced_at, &DateTime.utc_now/0))",
        "change(set_attribute(:last_synced_at, &DateTime.utc_now/0))\nchange #{inspect(FakePush)}"
      )
    end)
  end

  # And fill in CanResync. Here anyone with the :operator role may resync.
  defp allow_operators(recipe) do
    edit_source(recipe, @can_resync, fn source ->
      String.replace(
        source,
        "def match?(_actor, _context, _opts), do: false",
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :operator"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp customer(recipe) do
    recipe.modules[Customer]
    |> Ash.Changeset.for_create(:create, %{name: "Acme"})
    |> Ash.create!()
  end

  defp start_sync(recipe, subject \\ nil) do
    subject = subject || customer(recipe)

    recipe.modules[CustomerSync]
    |> Ash.Changeset.for_create(:create, %{subject_id: subject.id})
    |> Ash.create()
  end

  # Runs the attempt the scheduler would run next, the way
  # `Timeline` does once a retry's backoff has passed.
  defp push(sync, attempt) do
    sync.__struct__
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.find(&(&1.step == :syncing))
    |> Scheduler.execute(reload(sync), attempt: attempt)
  end

  defp resync(sync, actor \\ @operator) do
    sync
    |> Ash.Changeset.for_update(:resync, %{}, actor: actor)
    |> Ash.update()
  end

  defp reload(sync), do: Ash.get!(sync.__struct__, sync.id)

  defp log(recipe), do: recipe.modules[CustomerSyncTransition] |> Ash.read!()

  defp retry(resource) do
    resource |> AshWorkflow.Info.steps() |> Enum.find(&(&1.name == :syncing)) |> Map.get(:retry)
  end

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the sync edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = sync_for_customers(tmp_dir)
      subject = recipe.modules[Customer]

      assert attributes(subject) == attributes(Customer)
      assert actions(subject) == actions(Customer)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Customer)) == [:sync]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Customer)) == [:synced?]
    end

    test "is synced once its sync is", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      customer = customer(recipe)

      {:ok, _sync} = start_sync(recipe, customer)
      refute Ash.load!(customer, :synced?).synced?

      assert Timeline.run_due(recipe.modules[CustomerSync]) == 1
      assert Ash.load!(customer, :synced?).synced?
    end
  end

  test "creates a missing subject in the given domain and syncs against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @files
      |> generate([inspect(Account), "--domain", inspect(Domain)])
      |> compile(tmp_dir)

    account_module = recipe.modules[Account]
    sync_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Sync.AccountSync]

    assert Ash.Resource.Info.data_layer(account_module) == Ash.DataLayer.Ets
    assert account_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    account = account_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    sync =
      sync_module
      |> Ash.Changeset.for_create(:create, %{subject_id: account.id})
      |> Ash.create!()

    assert sync.state == :syncing
    assert Ash.load!(account, sync: :id).sync.id == sync.id

    assert Timeline.run_due(sync_module) == 1
    assert %{state: :synced, last_synced_at: %DateTime{}} = reload(sync)
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Customer), "--max-attempts", "3"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.sync", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  test "a subject has at most one sync", %{tmp_dir: tmp_dir} do
    recipe = sync_for_customers(tmp_dir)
    customer = customer(recipe)

    assert {:ok, _sync} = start_sync(recipe, customer)
    assert {:error, %Ash.Error.Invalid{}} = start_sync(recipe, customer)
  end

  describe "CanResync" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Customer)]
        |> generate()
        |> compile(tmp_dir)

      {:ok, sync} = start_sync(recipe)
      Timeline.run_due(recipe.modules[CustomerSync])

      assert {:error, %Ash.Error.Forbidden{}} = sync |> reload() |> resync()
      assert reload(sync).state == :synced

      assert Enum.any?(recipe.notices, &String.contains?(&1, "Nobody can resync yet"))
    end

    test "lets an operator resync once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      {:ok, sync} = start_sync(recipe)
      Timeline.run_due(recipe.modules[CustomerSync])
      sync = reload(sync)

      assert {:error, %Ash.Error.Forbidden{}} = resync(sync, %{id: "other", role: :viewer})
      assert {:ok, %{state: :syncing}} = resync(sync)
    end
  end

  describe "pushing" do
    test "a push that succeeds moves the sync to synced and records the external system's id",
         %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      sync_module = recipe.modules[CustomerSync]
      {:ok, sync} = start_sync(recipe)

      assert sync.state == :syncing
      assert Timeline.run_due(sync_module) == 1

      assert %{state: :synced, external_id: external_id, last_synced_at: %DateTime{}} =
               reload(sync)

      assert external_id == "ext-#{sync.id}"
      assert Timeline.run_due(sync_module) == 0
    end

    test "a push that fails is retried after the backoff and can then succeed", %{
      tmp_dir: tmp_dir
    } do
      recipe = sync_for_customers(tmp_dir)
      {:ok, sync} = start_sync(recipe)
      FakePush.respond([:error, :error])

      assert {:retry, 30_000} = push(sync, 1)
      assert %{state: :syncing, last_synced_at: nil} = reload(sync)

      assert {:retry, 30_000} = push(sync, 2)
      assert {:ok, %{state: :synced}} = push(sync, 3)
      assert %{external_id: "ext-" <> _id, last_synced_at: %DateTime{}} = reload(sync)
    end

    test "a push that fails on every attempt moves the sync to failed", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      {:ok, sync} = start_sync(recipe)
      FakePush.respond([:error, :error, :error])

      assert {:retry, _delay} = push(sync, 1)
      assert {:retry, _delay} = push(sync, 2)
      assert {:ok, %{state: :failed}} = push(sync, 3)

      assert %{external_id: nil, last_synced_at: nil} = reload(sync)
      assert Timeline.run_due(recipe.modules[CustomerSync]) == 0

      assert [%{to_state: :failed}] =
               recipe |> log() |> Enum.filter(&(&1.triggered_by == :error_path))
    end
  end

  describe "resync" do
    test "returns a synced sync to syncing and pushes it again", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      sync_module = recipe.modules[CustomerSync]
      {:ok, sync} = start_sync(recipe)

      Timeline.run_due(sync_module)
      %{last_synced_at: first_synced_at} = synced = reload(sync)

      assert {:ok, %{state: :syncing}} = resync(synced)
      assert Timeline.run_due(sync_module) == 1

      resynced = reload(sync)
      assert resynced.state == :synced
      assert DateTime.after?(resynced.last_synced_at, first_synced_at)
    end

    test "returns a failed sync to syncing with a fresh set of attempts", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      {:ok, sync} = start_sync(recipe)
      FakePush.respond([:error, :error, :error, :error])

      Enum.each(1..3, &push(sync, &1))
      assert {:ok, %{state: :syncing}} = sync |> reload() |> resync()

      assert {:retry, _delay} = push(sync, 1)
      assert {:ok, %{state: :synced}} = push(sync, 2)

      assert recipe |> log() |> Enum.map(& &1.to_state) |> Enum.sort() ==
               [:failed, :synced, :syncing, :syncing]
    end
  end

  describe "--max-attempts and --backoff" do
    test "set the syncing step's retry", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir, ["--max-attempts", "7", "--backoff", "2m"])

      assert %{max_attempts: 7, backoff: {2, :minutes}} =
               retry(recipe.modules[CustomerSync])
    end

    test "default to five attempts with an exponential backoff", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir, [])

      assert %{max_attempts: 5, backoff: :exponential} = retry(recipe.modules[CustomerSync])
    end

    for {flag, backoff} <- [
          {"10s", "({10, :seconds})"},
          {"30m", "({30, :minutes})"},
          {"12h", "({12, :hours})"},
          {"2d", "({2, :days})"},
          {"2w", "({14, :days})"},
          {"exponential", "(:exponential)"}
        ] do
      test "--backoff parses #{flag} as backoff#{backoff}" do
        recipe = generate([inspect(Customer), "--backoff", unquote(flag)])

        assert source!(recipe, @sync_file) =~ "backoff#{unquote(backoff)}"
      end
    end

    for {argv, message} <- [
          {["--backoff", "2y"], "--backoff must be exponential or look like"},
          {["--max-attempts", "0"], "--max-attempts must be a positive integer"}
        ] do
      test "reports an issue for #{Enum.join(argv, " ")}" do
        igniter =
          @files
          |> project()
          |> Igniter.compose_task("ash_workflow.gen.sync", [inspect(Customer) | unquote(argv)])

        assert Enum.any?(igniter.issues, &String.contains?(&1, unquote(message)))
      end
    end
  end

  test "generates a Postgres-backed resource on the subject's repo", %{tmp_dir: tmp_dir} do
    recipe =
      [
        "test/support/recipe_fixtures/transition_log/postgres_domain.ex",
        "test/support/recipe_fixtures/transition_log/postgres_ticket.ex"
      ]
      |> generate(["AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket"])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketSync: "postgres_ticket_syncs",
          PostgresTicketSyncTransition: "postgres_ticket_syncs_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Customer), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.sync", [inspect(Account)])

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
