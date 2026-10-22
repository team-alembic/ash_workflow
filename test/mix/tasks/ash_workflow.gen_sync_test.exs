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
  @checks "lib/ash_workflow_test/recipe_fixtures/sync/customer_sync/checks"
  @deny_all "def match?(_actor, _context, _opts), do: false"
  @creator %{id: "creator", role: :account_manager}
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
    |> allow_creators()
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

  # And fill in CanCreate and CanResync. Here any actor may create a sync, and
  # anyone with the :operator role may resync.
  defp allow_creators(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_create.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_operators(recipe) do
    edit_source(recipe, "#{@checks}/can_resync.ex", fn source ->
      String.replace(
        source,
        @deny_all,
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

  # The "Resync after the subject changes" pattern from the sync recipe page.
  defp follow_subject_changes(recipe) do
    sync = inspect(CustomerSync)

    edit_source(recipe, @sync_file, fn source ->
      source
      |> String.replace("timestamps()", """
      timestamps()
      attribute :needs_resync?, :boolean, default: false, allow_nil?: false, public?: true
      """)
      |> String.replace("defaults([:read])", """
      defaults([:read])

      update :request_resync do
        require_atomic? false
        change set_attribute(:needs_resync?, true)
      end

      update :resync do
        require_atomic? false
        change set_attribute(:needs_resync?, false)
      end
      """)
      |> String.replace("policies do", """
      policies do
        policy action(:request_resync) do
          authorize_if always()
        end
      """)
      |> String.replace("code_interface do", """
      oban do
        triggers do
          trigger :resync_changed do
            action :resync
            where expr(needs_resync? and state in [:synced, :failed])
            worker_module_name #{sync}.AshOban.Worker.ResyncChanged
            scheduler_module_name #{sync}.AshOban.Scheduler.ResyncChanged
          end
        end
      end

      code_interface do
      """)
    end)
  end

  defp customer(recipe) do
    recipe.modules[Customer]
    |> Ash.Changeset.for_create(:create, %{name: "Acme"})
    |> Ash.create!()
  end

  defp start_sync(recipe, subject \\ nil, actor \\ @creator) do
    subject = subject || customer(recipe)

    recipe.modules[CustomerSync]
    |> Ash.Changeset.for_create(:create, %{subject_id: subject.id}, actor: actor)
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

  # A named timeline with nothing to sweep, so async tests do not share one.
  defp start_timeline do
    name = Module.concat(__MODULE__, "Timeline#{System.unique_integer([:positive])}")
    start_supervised!({Timeline, name: name, resources: [], look_ahead_ms: 60_000})

    name
  end

  # What `AshWorkflow.Scheduler.Precise` does when a sync enters :syncing.
  defp arm(timeline, sync) do
    works =
      sync.__struct__ |> AshWorkflow.Info.scheduled_work() |> Enum.filter(&(&1.step == :syncing))

    Timeline.deadline_changed(sync, works, timeline)
  end

  defp await_state(sync, state, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(10)
      reload(sync).state
    end)
    |> Enum.find(&(&1 == state or System.monotonic_time(:millisecond) > deadline))
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

    test "is not synced, rather than nil, without a sync", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)

      assert Ash.load!(customer(recipe), :synced?).synced? == false
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
      |> allow_creators("lib/ash_workflow_test/recipe_fixtures/sync/account_sync/checks")
      |> compile(tmp_dir)

    account_module = recipe.modules[Account]
    sync_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Sync.AccountSync]

    assert Ash.Resource.Info.data_layer(account_module) == Ash.DataLayer.Ets
    assert account_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    account = account_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    sync =
      sync_module
      |> Ash.Changeset.for_create(:create, %{subject_id: account.id}, actor: @creator)
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

  describe "CanCreate" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Customer)]
        |> generate()
        |> compile(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = start_sync(recipe)
      assert Ash.read!(recipe.modules[CustomerSync]) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can create or resync a sync yet")
             )
    end

    test "lets an actor create a sync once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = start_sync(recipe, nil, nil)
      assert {:ok, %{state: :syncing}} = start_sync(recipe)
    end
  end

  describe "CanResync" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Customer)]
        |> generate()
        |> allow_creators()
        |> compile(tmp_dir)

      {:ok, sync} = start_sync(recipe)
      Timeline.run_due(recipe.modules[CustomerSync])

      assert {:error, %Ash.Error.Forbidden{}} = sync |> reload() |> resync()
      assert reload(sync).state == :synced
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
      FakePush.respond(sync, [:error, :error])

      assert {:retry, 30_000} = push(sync, 1)
      assert %{state: :syncing, last_synced_at: nil} = reload(sync)

      assert {:retry, 30_000} = push(sync, 2)
      assert {:ok, %{state: :synced}} = push(sync, 3)
      assert %{external_id: "ext-" <> _id, last_synced_at: %DateTime{}} = reload(sync)
    end

    test "a push that fails on every attempt moves the sync to failed", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir)
      {:ok, sync} = start_sync(recipe)
      FakePush.respond(sync, [:error, :error, :error])

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

    # The timeline numbers each attempt and re-arms a failed one after the
    # backoff, so the attempt count here comes from the library.
    test "returns a failed sync to syncing with a fresh set of attempts", %{tmp_dir: tmp_dir} do
      recipe = sync_for_customers(tmp_dir, ["--max-attempts", "3", "--backoff", "1s"])
      timeline = start_timeline()
      {:ok, sync} = start_sync(recipe)
      FakePush.respond(sync, [:error, :error, :error, :error, :ok])

      arm(timeline, sync)
      assert await_state(sync, :failed) == :failed
      assert FakePush.remaining(sync) == [:error, :ok]

      assert {:ok, %{state: :syncing} = resynced} = sync |> reload() |> resync()
      arm(timeline, resynced)

      assert await_state(sync, :synced) == :synced
      assert FakePush.remaining(sync) == []

      assert recipe |> log() |> Enum.map(& &1.to_state) |> Enum.sort() ==
               [:failed, :synced, :syncing, :syncing]
    end

    test "a flagged settled sync is resynced by the trigger and the flag is cleared", %{
      tmp_dir: tmp_dir
    } do
      recipe =
        [inspect(Customer)]
        |> generate()
        |> fill_in_push()
        |> allow_creators()
        |> allow_operators()
        |> follow_subject_changes()
        |> compile(tmp_dir)

      sync_module = recipe.modules[CustomerSync]
      {:ok, sync} = start_sync(recipe)

      flagged =
        sync
        |> Ash.Changeset.for_update(:request_resync, %{}, actor: @creator)
        |> Ash.update!()

      assert %{state: :syncing, needs_resync?: true} = flagged
      AshOban.Test.refute_would_schedule(flagged, :resync_changed)

      assert Timeline.run_due(sync_module) == 1
      settled = reload(sync)
      assert %{state: :synced, needs_resync?: true} = settled
      AshOban.Test.assert_would_schedule(settled, :resync_changed)

      trigger = AshOban.Info.oban_trigger(sync_module, :resync_changed)

      assert {:ok, %{state: :syncing, needs_resync?: false}} =
               settled
               |> Ash.Changeset.for_update(trigger.action, %{}, actor: @operator)
               |> Ash.update()

      assert Timeline.run_due(sync_module) == 1
      resynced = reload(sync)
      assert %{state: :synced, needs_resync?: false} = resynced
      AshOban.Test.refute_would_schedule(resynced, :resync_changed)
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
