defmodule Mix.Tasks.AshWorkflow.Gen.ExpiryTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Expiry.Contract
  alias AshWorkflowTest.RecipeFixtures.Expiry.ContractExpiry
  alias AshWorkflowTest.RecipeFixtures.Expiry.ContractExpiryTransition
  alias AshWorkflowTest.RecipeFixtures.Expiry.Domain
  alias AshWorkflowTest.RecipeFixtures.Expiry.Lease
  alias AshWorkflowTest.RecipeFixtures.Expiry.Licence

  @fixtures "test/support/recipe_fixtures/expiry"
  @files Enum.map(~w(domain contract lease), &"#{@fixtures}/#{&1}.ex")
  @checks "lib/ash_workflow_test/recipe_fixtures/expiry/contract_expiry/checks"
  @deny_all "def match?(_actor, _context, _opts), do: false"
  @creator %{id: "creator", role: :account_manager}
  @renewer %{id: "renewer", role: :renewer}

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.expiry", argv)
  end

  defp expiry_for_contracts(tmp_dir, argv \\ ["--notice-period", "30d"]) do
    [inspect(Contract) | argv]
    |> generate()
    |> allow_creators()
    |> allow_renewers()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanCreate and CanRenew. Here any actor may create an expiry, and anyone
  # with the :renewer role may renew.
  defp allow_creators(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_create.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_renewers(recipe) do
    edit_source(recipe, "#{@checks}/can_renew.ex", fn source ->
      String.replace(
        source,
        @deny_all,
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :renewer"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp contract(recipe) do
    recipe.modules[Contract]
    |> Ash.Changeset.for_create(:create, %{title: "Lease"})
    |> Ash.create!()
  end

  defp expire(recipe, subject, days_from_now, actor \\ @creator) do
    recipe.modules[ContractExpiry]
    |> Ash.Changeset.for_create(
      :create,
      %{subject_id: subject.id, expires_at: days_from_now(days_from_now)},
      actor: actor
    )
    |> Ash.create()
  end

  defp renew(expiry, expires_at, actor \\ @renewer) do
    expiry
    |> Ash.Changeset.for_update(:renew, %{expires_at: expires_at}, actor: actor)
    |> Ash.update()
  end

  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(), days, :day)

  defp reload(expiry), do: Ash.get!(expiry.__struct__, expiry.id)

  defp run_until_settled(resource, runs \\ 0) do
    case Timeline.run_due(resource) do
      0 -> runs
      _count -> run_until_settled(resource, runs + 1)
    end
  end

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the expiry edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = expiry_for_contracts(tmp_dir)
      subject = recipe.modules[Contract]

      assert attributes(subject) == attributes(Contract)
      assert actions(subject) == actions(Contract)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Contract)) == [:expiry]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Contract)) == [:expired?]
    end

    test "is not expired, rather than nil, without an expiry", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)

      assert Ash.load!(contract(recipe), :expired?).expired? == false
    end

    test "is expired once its expiry is", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)
      contract = contract(recipe)

      {:ok, expiry} = expire(recipe, contract, -1)
      refute Ash.load!(contract, :expired?).expired?

      run_until_settled(recipe.modules[ContractExpiry])
      assert Ash.load!(contract, :expired?).expired?

      {:ok, _renewed} = expiry |> reload() |> renew(days_from_now(90))
      refute Ash.load!(contract, :expired?).expired?
    end
  end

  test "creates a missing subject in the given domain and expires against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      [inspect(Licence), "--domain", inspect(Domain)]
      |> generate()
      |> allow_creators("lib/ash_workflow_test/recipe_fixtures/expiry/licence_expiry/checks")
      |> compile(tmp_dir)

    licence_module = recipe.modules[Licence]
    expiry_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Expiry.LicenceExpiry]

    assert Ash.Resource.Info.data_layer(licence_module) == Ash.DataLayer.Ets
    assert licence_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    licence = licence_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    expiry =
      expiry_module
      |> Ash.Changeset.for_create(
        :create,
        %{subject_id: licence.id, expires_at: days_from_now(1)},
        actor: @creator
      )
      |> Ash.create!()

    assert expiry.state == :active
    assert Ash.load!(licence, expiry: :id).expiry.id == expiry.id
    assert Ash.Resource.Info.attribute(expiry_module, :subject_id).type == Ash.Type.UUIDv7
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Contract), "--notice-period", "30d"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.expiry", argv)

    assert second.changed == %{}
  end

  test "warns and leaves an existing calculation of the same name as it is" do
    contract =
      "#{@fixtures}/contract.ex"
      |> File.read!()
      |> String.replace(
        "  attributes do",
        "  calculations do\n    calculate :expired?, :boolean, expr(false)\n  end\n\n  attributes do"
      )

    recipe =
      Igniter.Test.test_project(
        app_name: :ash_workflow,
        files:
          @files
          |> Map.new(&{&1, File.read!(&1)})
          |> Map.put("#{@fixtures}/contract.ex", contract)
      )
      |> run_task("ash_workflow.gen.expiry", [inspect(Contract)])

    assert [warning] = recipe.warnings
    assert warning =~ "#{inspect(Contract)} already has a calculation named :expired?"
    assert warning =~ "calculate :expired?, :boolean, expr(expiry.state == :expired"

    source = source!(recipe, "#{@fixtures}/contract.ex")
    assert source =~ ":expired?, :boolean, expr(false)"
    assert source =~ "has_one :expiry"
    refute source =~ "expiry.state == :expired"
  end

  test "warns on a second run that the subject edits are already there" do
    argv = [inspect(Contract)]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.expiry", argv)

    assert Enum.any?(
             second.warnings,
             &(&1 =~ "#{inspect(Contract)} already has a relationship named :expiry" and
                 &1 =~ "has_one :expiry")
           )
  end

  test "a subject has at most one expiry", %{tmp_dir: tmp_dir} do
    recipe = expiry_for_contracts(tmp_dir)
    contract = contract(recipe)

    assert {:ok, _expiry} = expire(recipe, contract, 90)
    assert {:error, %Ash.Error.Invalid{}} = expire(recipe, contract, 120)
  end

  describe "CanCreate" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Contract), "--notice-period", "30d"]
        |> generate()
        |> allow_renewers()
        |> compile(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = expire(recipe, contract(recipe), 90)
      assert {:error, %Ash.Error.Forbidden{}} = expire(recipe, contract(recipe), 90, nil)
      assert Ash.read!(recipe.modules[ContractExpiry]) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can create or renew an expiry yet")
             )
    end

    test "lets a creator create once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)

      assert {:error, %Ash.Error.Forbidden{}} = expire(recipe, contract(recipe), 90, nil)
      assert {:ok, %{state: :active}} = expire(recipe, contract(recipe), 90)
    end

    test "leaves reads open to every actor", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)
      {:ok, expiry} = expire(recipe, contract(recipe), 90)

      for actor <- [nil, %{id: "other", role: :tenant}] do
        assert [%{id: id}] = Ash.read!(recipe.modules[ContractExpiry], actor: actor)
        assert id == expiry.id
      end
    end
  end

  describe "CanRenew" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Contract), "--notice-period", "30d"]
        |> generate()
        |> allow_creators()
        |> compile(tmp_dir)

      {:ok, expiry} = expire(recipe, contract(recipe), 90)

      assert {:error, %Ash.Error.Forbidden{}} = renew(expiry, days_from_now(180))
      assert reload(expiry).expires_at == expiry.expires_at
    end

    test "lets a renewer renew once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)
      {:ok, expiry} = expire(recipe, contract(recipe), 90)

      assert {:error, %Ash.Error.Forbidden{}} =
               renew(expiry, days_from_now(180), %{id: "other", role: :tenant})

      assert {:ok, %{state: :active}} = renew(expiry, days_from_now(180))
    end
  end

  describe "the deadlines" do
    test "the notice period moves an expiry to expiring before it expires", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)
      expiry_module = recipe.modules[ContractExpiry]

      {:ok, distant} = expire(recipe, contract(recipe), 60)
      {:ok, near} = expire(recipe, contract(recipe), 10)

      assert Timeline.run_due(expiry_module) == 1
      assert reload(distant).state == :active
      assert reload(near).state == :expiring
      assert Timeline.run_due(expiry_module) == 0
    end

    test "an expiry whose expires_at has passed moves through expiring to expired", %{
      tmp_dir: tmp_dir
    } do
      recipe = expiry_for_contracts(tmp_dir)
      expiry_module = recipe.modules[ContractExpiry]
      {:ok, expiry} = expire(recipe, contract(recipe), -1)

      run_until_settled(expiry_module)
      assert reload(expiry).state == :expired

      log = recipe.modules[ContractExpiryTransition] |> Ash.read!() |> Enum.map(& &1.to_state)
      assert Enum.sort(log) == [:active, :expired, :expiring]
    end

    test "without --notice-period there is no expiring step", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir, [])
      expiry_module = recipe.modules[ContractExpiry]

      assert step_names(expiry_module) == [:active, :expired]
      refute Ash.Resource.Info.calculation(expiry_module, :expiring_at)

      {:ok, near} = expire(recipe, contract(recipe), 10)
      {:ok, lapsed} = expire(recipe, contract(recipe), -1)

      assert Timeline.run_due(expiry_module) == 1
      assert reload(near).state == :active
      assert reload(lapsed).state == :expired
    end
  end

  describe "renew" do
    for {state, days} <- [active: 60, expiring: 10, expired: -1] do
      test "returns an #{state} expiry to active and moves both deadlines", %{tmp_dir: tmp_dir} do
        recipe = expiry_for_contracts(tmp_dir)
        expiry_module = recipe.modules[ContractExpiry]
        {:ok, expiry} = expire(recipe, contract(recipe), unquote(days))

        run_until_settled(expiry_module)
        assert %{state: unquote(state)} = expiry = reload(expiry)

        expires_at = days_from_now(90)
        assert {:ok, %{state: :active}} = renew(expiry, expires_at)

        renewed = expiry_module |> Ash.get!(expiry.id) |> Ash.load!(:expiring_at)
        assert renewed.expires_at == expires_at

        assert DateTime.diff(expires_at, renewed.expiring_at, :second) == 30 * 86_400

        assert Timeline.run_due(expiry_module) == 0
      end
    end

    test "requires a new expires_at", %{tmp_dir: tmp_dir} do
      recipe = expiry_for_contracts(tmp_dir)
      {:ok, expiry} = expire(recipe, contract(recipe), 60)

      assert {:error, %Ash.Error.Invalid{}} =
               expiry
               |> Ash.Changeset.for_update(:renew, %{}, actor: @renewer)
               |> Ash.update()
    end
  end

  describe "--notice-period" do
    for {flag, interval} <- [
          {"10s", "-10, :second"},
          {"30m", "-30, :minute"},
          {"12h", "-12, :hour"},
          {"2d", "-2, :day"},
          {"2w", "-14, :day"}
        ] do
      test "parses #{flag} as an offset of #{interval}" do
        recipe = generate([inspect(Contract), "--notice-period", unquote(flag)])

        assert source!(recipe, "lib/ash_workflow_test/recipe_fixtures/expiry/contract_expiry.ex") =~
                 "datetime_add(expires_at, #{unquote(interval)})"
      end
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.expiry", [
          inspect(Contract),
          "--notice-period",
          "2y"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--notice-period must look like"))
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
        "--notice-period",
        "7d"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketExpiry: "postgres_ticket_expiries",
          PostgresTicketExpiryTransition: "postgres_ticket_expiries_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Contract), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.expiry", [inspect(Licence)])

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Pass --domain to create it"))
  end

  describe "the subject foreign key" do
    test "takes the type of the subject's primary key", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Lease)]
        |> generate()
        |> allow_creators("lib/ash_workflow_test/recipe_fixtures/expiry/lease_expiry/checks")
        |> compile(tmp_dir)

      expiry_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Expiry.LeaseExpiry]
      assert Ash.Resource.Info.attribute(expiry_module, :subject_id).type == Ash.Type.Integer

      lease =
        recipe.modules[Lease] |> Ash.Changeset.for_create(:create, %{id: 7}) |> Ash.create!()

      expiry =
        expiry_module
        |> Ash.Changeset.for_create(
          :create,
          %{subject_id: lease.id, expires_at: days_from_now(30)},
          actor: @creator
        )
        |> Ash.create!()

      assert Ash.load!(lease, expiry: :id).expiry.id == expiry.id
      assert Ash.load!(lease, :expired?).expired? == false
    end

    test "reports an issue for a subject with a composite primary key" do
      igniter =
        [
          "test/support/recipe_fixtures/approval/domain.ex",
          "test/support/recipe_fixtures/approval/ledger_line.ex"
        ]
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.expiry", [
          "AshWorkflowTest.RecipeFixtures.Approval.LedgerLine"
        ])

      assert Enum.any?(
               igniter.issues,
               &(&1 =~
                   "AshWorkflowTest.RecipeFixtures.Approval.LedgerLine has a composite primary key")
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
