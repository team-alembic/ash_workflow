defmodule Mix.Tasks.AshWorkflow.Gen.AcknowledgementTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.Domain
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.Policy
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.PolicyAcknowledgement
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.PolicyAcknowledgementTransition
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.Terms
  alias AshWorkflowTest.RecipeFixtures.Acknowledgement.User

  @fixtures "test/support/recipe_fixtures/acknowledgement"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex", "#{@fixtures}/policy.ex"]
  @checks "lib/ash_workflow_test/recipe_fixtures/acknowledgement/policy_acknowledgement/checks"
  @deny_all "def match?(_actor, _context, _opts), do: false"

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.acknowledgement", argv)
  end

  defp acknowledgement_for_policies(tmp_dir, argv \\ ["--overdue-after", "14d"]) do
    [inspect(Policy), "--person", inspect(User) | argv]
    |> generate()
    |> allow_requesters()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanRequest. Here any actor may open a request.
  defp allow_requesters(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_request.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp user(recipe, name \\ "person") do
    recipe.modules[User]
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  defp requester(recipe), do: user(recipe, "requester")

  defp policy(recipe) do
    recipe.modules[Policy]
    |> Ash.Changeset.for_create(:create, %{title: "Code of conduct"})
    |> Ash.create!()
  end

  defp request(recipe, subject, person) do
    {:ok, acknowledgement} = open_request(recipe, subject, person)
    acknowledgement
  end

  defp open_request(recipe, subject, person),
    do: open_request(recipe, subject, person, requester(recipe))

  defp open_request(recipe, subject, person, actor) do
    recipe.modules[PolicyAcknowledgement]
    |> Ash.Changeset.for_create(
      :request,
      %{subject_id: subject.id, person_id: person.id},
      actor: actor
    )
    |> Ash.create()
  end

  defp request_many(recipe, subject, people),
    do: request_many(recipe, subject, people, requester(recipe))

  defp request_many(recipe, subject, people, actor) do
    recipe.modules[PolicyAcknowledgement].request_many(
      subject.id,
      Enum.map(people, &%{person_id: &1.id}),
      actor: actor,
      bulk_options: [return_records?: true, return_errors?: true]
    )
  end

  defp requested_days_ago(recipe, subject, person, days) do
    recipe.modules[PolicyAcknowledgement]
    |> Ash.Changeset.for_create(
      :request,
      %{subject_id: subject.id, person_id: person.id},
      actor: requester(recipe)
    )
    |> Ash.Changeset.force_change_attribute(
      :requested_at,
      DateTime.add(DateTime.utc_now(), -days, :day)
    )
    |> Ash.create!()
  end

  defp acknowledge(acknowledgement, actor) do
    acknowledgement
    |> Ash.Changeset.for_update(:acknowledge, %{}, actor: actor)
    |> Ash.update()
  end

  defp acknowledged_by?(subject, actor) do
    Ash.load!(subject, :acknowledged_by_actor?, actor: actor).acknowledged_by_actor?
  end

  defp reload(acknowledgement), do: Ash.get!(acknowledgement.__struct__, acknowledgement.id)

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the acknowledgement edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = acknowledgement_for_policies(tmp_dir)
      subject = recipe.modules[Policy]

      assert attributes(subject) == attributes(Policy)
      assert actions(subject) == actions(Policy)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Policy)) == [:acknowledgements]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Policy)) == [:acknowledged_by_actor?]
    end

    test "is acknowledged by the actor once their own request is", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir)
      policy = policy(recipe)
      person = user(recipe)
      other = user(recipe, "other")

      acknowledgement = request(recipe, policy, person)
      request(recipe, policy, other)
      assert acknowledged_by?(policy, person) == false

      assert {:ok, %{state: :acknowledged}} = acknowledge(acknowledgement, person)

      assert acknowledged_by?(policy, person)
      refute acknowledged_by?(policy, other)
      assert acknowledged_by?(policy, nil) == false
    end

    test "records each transition with the person who made it", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir)
      person = user(recipe)

      {:ok, _acknowledged} = recipe |> request(policy(recipe), person) |> acknowledge(person)

      log = Ash.read!(recipe.modules[PolicyAcknowledgementTransition])

      assert log |> Enum.map(& &1.to_state) |> Enum.sort() == [:acknowledged, :pending]
      assert %{user_id: user_id} = Enum.find(log, &(&1.to_state == :acknowledged))
      assert user_id == person.id
    end
  end

  test "creates a missing subject in the given domain and acknowledges against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      ["#{@fixtures}/domain.ex", "#{@fixtures}/user.ex"]
      |> generate([inspect(Terms), "--person", inspect(User), "--domain", inspect(Domain)])
      |> allow_requesters(
        "lib/ash_workflow_test/recipe_fixtures/acknowledgement/terms_acknowledgement/checks"
      )
      |> compile(tmp_dir)

    terms_module = recipe.modules[Terms]

    acknowledgement_module =
      recipe.modules[AshWorkflowTest.RecipeFixtures.Acknowledgement.TermsAcknowledgement]

    assert Ash.Resource.Info.data_layer(terms_module) == Ash.DataLayer.Ets
    assert terms_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    terms = terms_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()
    person = user(recipe)

    acknowledgement =
      acknowledgement_module
      |> Ash.Changeset.for_create(
        :request,
        %{subject_id: terms.id, person_id: person.id},
        actor: requester(recipe)
      )
      |> Ash.create!()

    assert acknowledgement.state == :pending
    assert {:ok, %{state: :acknowledged}} = acknowledge(acknowledgement, person)
    assert acknowledged_by?(terms, person)
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Policy), "--person", inspect(User), "--overdue-after", "14d"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.acknowledgement", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  describe "acknowledge" do
    test "is allowed only for the request's own person", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir)
      person = user(recipe)
      acknowledgement = request(recipe, policy(recipe), person)

      assert {:error, %Ash.Error.Forbidden{}} =
               acknowledge(acknowledgement, user(recipe, "other"))

      assert {:error, %Ash.Error.Forbidden{}} = acknowledge(acknowledgement, nil)
      assert reload(acknowledgement).state == :pending

      assert {:ok, %{state: :acknowledged} = acknowledged} = acknowledge(acknowledgement, person)
      assert %DateTime{} = acknowledged.acknowledged_at

      assert Enum.any?(recipe.notices, &String.contains?(&1, "Only the person"))
    end
  end

  describe "request" do
    test "a person is asked at most once per subject", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir)
      policy = policy(recipe)
      person = user(recipe)

      first = request(recipe, policy, person)
      {:ok, acknowledged} = acknowledge(first, person)

      again = request(recipe, policy, person)

      assert again.id == first.id
      assert again.state == :acknowledged
      assert again.requested_at == first.requested_at
      assert again.acknowledged_at == acknowledged.acknowledged_at
      assert [_one] = Ash.read!(recipe.modules[PolicyAcknowledgement])

      log =
        recipe.modules[PolicyAcknowledgementTransition] |> Ash.read!() |> Enum.map(& &1.to_state)

      assert Enum.sort(log) == [:acknowledged, :pending]
    end

    test "request_many opens a row for each person, keeping rows already open", %{
      tmp_dir: tmp_dir
    } do
      recipe = acknowledgement_for_policies(tmp_dir)
      acknowledgement_module = recipe.modules[PolicyAcknowledgement]
      policy = policy(recipe)
      asked = user(recipe, "asked")
      {:ok, _acknowledged} = recipe |> request(policy, asked) |> acknowledge(asked)
      people = [asked, user(recipe, "new"), user(recipe, "newer")]

      for listed <- [Enum.take(people, 2), people] do
        assert %{status: :success} = request_many(recipe, policy, listed)
      end

      acknowledgements = Ash.read!(acknowledgement_module)
      by_person = Map.new(acknowledgements, &{&1.person_id, &1.state})

      assert by_person == %{
               asked.id => :acknowledged,
               Enum.at(people, 1).id => :pending,
               Enum.at(people, 2).id => :pending
             }

      person_by_acknowledgement = Map.new(acknowledgements, &{&1.id, &1.person_id})

      initial_rows_by_person =
        recipe.modules[PolicyAcknowledgementTransition]
        |> Ash.read!()
        |> Enum.filter(&(&1.triggered_by == :initial))
        |> Enum.frequencies_by(&person_by_acknowledgement[&1.workflow_id])

      assert initial_rows_by_person == Map.new(people, &{&1.id, 1})
    end
  end

  describe "CanRequest" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Policy), "--person", inspect(User)]
        |> generate()
        |> compile(tmp_dir)

      policy = policy(recipe)
      person = user(recipe)

      assert {:error, %Ash.Error.Forbidden{}} = open_request(recipe, policy, person)
      assert {:error, %Ash.Error.Forbidden{}} = open_request(recipe, policy, person, nil)

      assert %{status: :error, errors: [%Ash.Error.Forbidden{} | _]} =
               request_many(recipe, policy, [person, user(recipe, "other")])

      assert Ash.read!(recipe.modules[PolicyAcknowledgement]) == []
      assert Enum.any?(recipe.notices, &String.contains?(&1, "Nobody can open a request yet"))
    end

    test "lets a requester open requests once the application permits them", %{
      tmp_dir: tmp_dir
    } do
      recipe = acknowledgement_for_policies(tmp_dir)
      policy = policy(recipe)
      people = [user(recipe), user(recipe, "other")]

      assert {:error, %Ash.Error.Forbidden{}} = open_request(recipe, policy, hd(people), nil)

      assert %{status: :error, errors: [%Ash.Error.Forbidden{} | _]} =
               request_many(recipe, policy, people, nil)

      assert Ash.read!(recipe.modules[PolicyAcknowledgement]) == []

      assert %{status: :success, records: [_, _]} = request_many(recipe, policy, people)
      assert {:ok, %{state: :pending}} = open_request(recipe, policy, user(recipe, "third"))
    end
  end

  describe "--overdue-after" do
    test "moves an unacknowledged request to overdue once the deadline passes", %{
      tmp_dir: tmp_dir
    } do
      recipe = acknowledgement_for_policies(tmp_dir)
      acknowledgement_module = recipe.modules[PolicyAcknowledgement]
      policy = policy(recipe)
      late_person = user(recipe, "late")

      fresh = request(recipe, policy, user(recipe))
      late = requested_days_ago(recipe, policy, late_person, 15)

      assert Timeline.run_due(acknowledgement_module) == 1
      assert reload(fresh).state == :pending
      assert reload(late).state == :overdue

      assert {:ok, %{state: :acknowledged}} = late |> reload() |> acknowledge(late_person)
      assert acknowledged_by?(policy, late_person)
    end

    test "leaves an acknowledged request alone after the deadline", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir)
      person = user(recipe)
      late = requested_days_ago(recipe, policy(recipe), person, 15)

      {:ok, _acknowledged} = acknowledge(late, person)

      assert Timeline.run_due(recipe.modules[PolicyAcknowledgement]) == 0
      assert reload(late).state == :acknowledged
    end

    test "without it, no overdue step is generated", %{tmp_dir: tmp_dir} do
      recipe = acknowledgement_for_policies(tmp_dir, [])
      acknowledgement_module = recipe.modules[PolicyAcknowledgement]

      assert step_names(acknowledgement_module) == [:pending, :acknowledged]
      assert AshWorkflow.Info.scheduled_work(acknowledgement_module) == []
    end

    for {flag, duration} <- [
          {"30m", {30, :minutes}},
          {"12h", {12, :hours}},
          {"2d", {2, :days}},
          {"2w", {14, :days}}
        ] do
      test "parses #{flag} as #{inspect(duration)}", %{tmp_dir: tmp_dir} do
        recipe = acknowledgement_for_policies(tmp_dir, ["--overdue-after", unquote(flag)])

        assert [%{fire_after: unquote(Macro.escape(duration)), field: :requested_at}] =
                 recipe.modules[PolicyAcknowledgement]
                 |> AshWorkflow.Info.steps()
                 |> Enum.flat_map(& &1.timeouts)
      end
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.acknowledgement", [
          inspect(Policy),
          "--person",
          inspect(User),
          "--overdue-after",
          "2y"
        ])

      assert Enum.any?(igniter.issues, &String.contains?(&1, "--overdue-after must look like"))
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
        "--person",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer",
        "--overdue-after",
        "7d"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketAcknowledgement: "postgres_ticket_acknowledgements",
          PostgresTicketAcknowledgementTransition: "postgres_ticket_acknowledgements_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Policy), "--person", inspect(User), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.acknowledgement", [
        inspect(Terms),
        "--person",
        inspect(User)
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
