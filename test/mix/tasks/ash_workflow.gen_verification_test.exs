defmodule Mix.Tasks.AshWorkflow.Gen.VerificationTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler
  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Verification.Domain
  alias AshWorkflowTest.RecipeFixtures.Verification.IdentityDocument
  alias AshWorkflowTest.RecipeFixtures.Verification.IdentityDocumentVerification
  alias AshWorkflowTest.RecipeFixtures.Verification.IdentityDocumentVerificationTransition
  alias AshWorkflowTest.RecipeFixtures.Verification.Passport
  alias AshWorkflowTest.RecipeFixtures.Verification.Provider

  @fixtures "test/support/recipe_fixtures/verification"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/identity_document.ex"]
  @verification "lib/ash_workflow_test/recipe_fixtures/verification/identity_document_verification.ex"
  @checks "lib/ash_workflow_test/recipe_fixtures/verification/identity_document_verification/checks"
  @can_review "#{@checks}/can_review.ex"
  @deny_all "def match?(_actor, _context, _opts), do: false"
  @submitter %{id: "submitter", role: :applicant}
  @reviewer %{id: "reviewer", role: :reviewer}

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.verification", argv)
  end

  defp verification_for_documents(tmp_dir, argv \\ []) do
    [inspect(IdentityDocument) | argv]
    |> generate()
    |> call_provider()
    |> allow_submitters()
    |> allow_reviewers()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in the
  # :verify action with the provider call, and fill in CanSubmit and
  # CanReview. Here any actor may submit, and anyone with the :reviewer role
  # may review.
  defp call_provider(recipe) do
    edit_source(recipe, @verification, fn source ->
      String.replace(
        source,
        ~r/update :verify do\n/,
        "\\0change #{inspect(Provider)}\n"
      )
    end)
  end

  defp allow_submitters(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_submit.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_reviewers(recipe) do
    edit_source(recipe, @can_review, fn source ->
      String.replace(
        source,
        @deny_all,
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :reviewer"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp document(recipe, number) do
    recipe.modules[IdentityDocument]
    |> Ash.Changeset.for_create(:create, %{number: number})
    |> Ash.create!()
  end

  defp submit(recipe, subject) do
    {:ok, verification} = submit(recipe, subject, @submitter)
    verification
  end

  defp submit(recipe, subject, actor) do
    recipe.modules[IdentityDocumentVerification]
    |> Ash.Changeset.for_create(:submit, %{subject_id: subject.id}, actor: actor)
    |> Ash.create()
  end

  defp started(recipe, number) do
    recipe
    |> submit(document(recipe, number))
    |> transition(:begin)
    |> then(fn {:ok, verification} -> verification end)
  end

  defp transition(verification, action, actor \\ nil) do
    verification
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
  end

  defp reload(verification), do: Ash.get!(verification.__struct__, verification.id)

  defp verifying_work(resource) do
    resource
    |> AshWorkflow.Info.scheduled_work()
    |> Enum.find(&(&1.step == :verifying))
  end

  # Runs every attempt the step's retry block allows through the scheduler,
  # since `Timeline.run_due/2` only runs the first.
  defp run_every_attempt(verification) do
    work = verifying_work(verification.__struct__)

    Enum.map(1..work.retry.max_attempts, fn attempt ->
      Scheduler.execute(work, reload(verification), attempt: attempt)
    end)
  end

  defp in_review(recipe) do
    verification = started(recipe, "unreachable")
    run_every_attempt(verification)
    reload(verification)
  end

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the verification edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = verification_for_documents(tmp_dir)
      subject = recipe.modules[IdentityDocument]

      assert attributes(subject) == attributes(IdentityDocument)
      assert actions(subject) == actions(IdentityDocument)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(IdentityDocument)) ==
               [:verifications, :latest_verification]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(IdentityDocument)) == [:verified?]
    end

    test "is not verified, rather than nil, without a verification", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)

      assert Ash.load!(document(recipe, "genuine"), :verified?).verified? == false
    end

    test "is verified once its latest verification is", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      document = document(recipe, "forged")

      {:ok, rejected} = recipe |> submit(document) |> transition(:begin)
      Timeline.run_due(recipe.modules[IdentityDocumentVerification])
      assert reload(rejected).state == :rejected
      refute Ash.load!(document, :verified?).verified?

      {:ok, document} =
        document
        |> Ash.Changeset.for_update(:correct, %{number: "genuine"})
        |> Ash.update()

      {:ok, _verified} = recipe |> submit(document) |> transition(:begin)
      Timeline.run_due(recipe.modules[IdentityDocumentVerification])

      document = Ash.load!(document, [:verified?, :verifications])
      assert document.verified?
      assert length(document.verifications) == 2
    end

    test "is not verified while a new verification of a verified subject runs", %{
      tmp_dir: tmp_dir
    } do
      recipe = verification_for_documents(tmp_dir)
      document = document(recipe, "genuine")

      {:ok, _verified} = recipe |> submit(document) |> transition(:begin)
      Timeline.run_due(recipe.modules[IdentityDocumentVerification])
      assert Ash.load!(document, :verified?).verified?

      {:ok, resubmitted} = recipe |> submit(document) |> transition(:begin)
      assert resubmitted.state == :verifying
      refute Ash.load!(document, :verified?).verified?

      Timeline.run_due(recipe.modules[IdentityDocumentVerification])
      assert Ash.load!(document, :verified?).verified?
    end
  end

  test "creates a missing subject in the given domain and verifies against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @files
      |> generate([inspect(Passport), "--domain", inspect(Domain)])
      |> allow_submitters(
        "lib/ash_workflow_test/recipe_fixtures/verification/passport_verification/checks"
      )
      |> compile(tmp_dir)

    passport_module = recipe.modules[Passport]

    verification_module =
      recipe.modules[AshWorkflowTest.RecipeFixtures.Verification.PassportVerification]

    assert Ash.Resource.Info.data_layer(passport_module) == Ash.DataLayer.Ets
    assert passport_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    passport = passport_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    verification =
      verification_module
      |> Ash.Changeset.for_create(:submit, %{subject_id: passport.id}, actor: @submitter)
      |> Ash.create!()

    assert verification.state == :submitted

    assert Ash.load!(passport, latest_verification: :id).latest_verification.id ==
             verification.id
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(IdentityDocument)]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.verification", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  describe "the provider" do
    test "a submitted verification waits for begin", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = submit(recipe, document(recipe, "genuine"))

      assert Timeline.run_due(recipe.modules[IdentityDocumentVerification]) == 0
      assert reload(verification).state == :submitted
    end

    test "a passing outcome verifies", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = started(recipe, "genuine")

      assert Timeline.run_due(recipe.modules[IdentityDocumentVerification]) == 1
      assert %{state: :verified, outcome: :passed} = reload(verification)

      log =
        recipe.modules[IdentityDocumentVerificationTransition]
        |> Ash.read!()
        |> Enum.map(& &1.to_state)

      assert Enum.sort(log) == [:submitted, :verified, :verifying]
    end

    test "a failing outcome rejects without review", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = started(recipe, "forged")

      assert Timeline.run_due(recipe.modules[IdentityDocumentVerification]) == 1
      assert %{state: :rejected, outcome: :failed} = reload(verification)
    end

    test "a failing provider is retried, then moves to needs_review", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = started(recipe, "unreachable")

      assert [{:retry, _}, {:retry, _}, {:ok, %{state: :needs_review}}] =
               run_every_attempt(verification)

      assert %{state: :needs_review, outcome: nil} = reload(verification)
    end

    test "--max-attempts sets the attempts before needs_review", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir, ["--max-attempts", "5"])
      verification = started(recipe, "unreachable")

      assert verifying_work(recipe.modules[IdentityDocumentVerification]).retry.max_attempts == 5

      assert [{:retry, _}, {:retry, _}, {:retry, _}, {:retry, _}, {:ok, _}] =
               run_every_attempt(verification)
    end

    test "--max-attempts 1 generates no retry block and reviews on the first failure", %{
      tmp_dir: tmp_dir
    } do
      recipe = verification_for_documents(tmp_dir, ["--max-attempts", "1"])
      verification = started(recipe, "unreachable")

      refute source!(recipe, @verification) =~ "retry do"

      assert Timeline.run_due(recipe.modules[IdentityDocumentVerification]) == 1
      assert reload(verification).state == :needs_review
    end

    test "a :verify that writes no outcome moves to needs_review", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(IdentityDocument), "--max-attempts", "1"]
        |> generate()
        |> allow_submitters()
        |> compile(tmp_dir)

      verification = started(recipe, "genuine")

      assert Timeline.run_due(recipe.modules[IdentityDocumentVerification]) == 1
      assert %{state: :needs_review, outcome: nil} = reload(verification)

      assert Enum.any?(recipe.notices, &String.contains?(&1, "The :verify action is empty"))
    end

    test "every step the workflow generates", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)

      assert step_names(recipe.modules[IdentityDocumentVerification]) ==
               [:submitted, :verifying, :needs_review, :verified, :rejected]
    end
  end

  describe "CanSubmit" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(IdentityDocument)]
        |> generate()
        |> call_provider()
        |> allow_reviewers()
        |> compile(tmp_dir)

      document = document(recipe, "genuine")

      assert {:error, %Ash.Error.Forbidden{}} = submit(recipe, document, @submitter)
      assert {:error, %Ash.Error.Forbidden{}} = submit(recipe, document, nil)
      assert Ash.read!(recipe.modules[IdentityDocumentVerification]) == []

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "Nobody can submit a verification")
             )
    end

    test "lets a submitter submit once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      document = document(recipe, "genuine")

      assert {:error, %Ash.Error.Forbidden{}} = submit(recipe, document, nil)
      assert {:ok, %{state: :submitted}} = submit(recipe, document, @submitter)
    end

    test "leaves reads open to every actor", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = submit(recipe, document(recipe, "genuine"))

      for actor <- [nil, %{id: "other", role: :applicant}] do
        assert [%{id: id}] = Ash.read!(recipe.modules[IdentityDocumentVerification], actor: actor)
        assert id == verification.id
      end
    end
  end

  describe "CanReview" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(IdentityDocument)]
        |> generate()
        |> call_provider()
        |> allow_submitters()
        |> compile(tmp_dir)

      verification = in_review(recipe)

      for action <- [:approve, :reject] do
        assert {:error, %Ash.Error.Forbidden{}} = transition(verification, action, @reviewer)
      end

      assert reload(verification).state == :needs_review

      assert Enum.any?(
               recipe.notices,
               &String.contains?(&1, "decide one in review yet")
             )
    end

    test "lets a reviewer approve once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = in_review(recipe)

      assert {:error, %Ash.Error.Forbidden{}} =
               transition(verification, :approve, %{id: "applicant", role: :applicant})

      assert {:ok, %{state: :verified}} = transition(verification, :approve, @reviewer)
    end

    test "lets a reviewer reject once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = verification_for_documents(tmp_dir)
      verification = in_review(recipe)

      assert {:ok, %{state: :rejected}} = transition(verification, :reject, @reviewer)
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
          PostgresTicketVerification: "postgres_ticket_verifications",
          PostgresTicketVerificationTransition: "postgres_ticket_verifications_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(IdentityDocument), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for --max-attempts below 1" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.verification", [
        inspect(IdentityDocument),
        "--max-attempts",
        "0"
      ])

    assert Enum.any?(
             igniter.issues,
             &String.contains?(&1, "--max-attempts must be a positive integer")
           )
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.verification", [inspect(Passport)])

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
