defmodule Mix.Tasks.AshWorkflow.Gen.PublicationTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Publication.Domain
  alias AshWorkflowTest.RecipeFixtures.Publication.Page
  alias AshWorkflowTest.RecipeFixtures.Publication.Post
  alias AshWorkflowTest.RecipeFixtures.Publication.PostPublication
  alias AshWorkflowTest.RecipeFixtures.Publication.PostPublicationTransition

  @fixtures "test/support/recipe_fixtures/publication"
  @files ["#{@fixtures}/domain.ex", "#{@fixtures}/post.ex"]
  @can_publish "lib/ash_workflow_test/recipe_fixtures/publication/post_publication/checks/can_publish.ex"
  @editor %{id: "editor", role: :editor}

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.publication", argv)
  end

  defp publication_for_posts(tmp_dir, argv \\ ["--with-unpublish-at"]) do
    [inspect(Post) | argv]
    |> generate()
    |> allow_editors()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanPublish. Here anyone with the :editor role may publish.
  defp allow_editors(recipe) do
    edit_source(recipe, @can_publish, fn source ->
      String.replace(
        source,
        "def match?(_actor, _context, _opts), do: false",
        "def match?(actor, _context, _opts), do: is_map(actor) and actor.role == :editor"
      )
    end)
  end

  # `compile/2` reads every file from the project, not only the changed ones.
  defp edit_source(recipe, path, fun) do
    recipe
    |> update_in([Access.key!(:changed), path], fun)
    |> update_in([Access.key!(:igniter), Access.key!(:assigns), :test_files, path], fun)
  end

  defp post(recipe) do
    recipe.modules[Post]
    |> Ash.Changeset.for_create(:create, %{title: "Launch"})
    |> Ash.create!()
  end

  defp draft(recipe, subject \\ nil) do
    subject = subject || post(recipe)

    recipe.modules[PostPublication]
    |> Ash.Changeset.for_create(:create, %{subject_id: subject.id})
    |> Ash.create()
  end

  defp draft!(recipe) do
    {:ok, publication} = draft(recipe)
    publication
  end

  defp move(publication, action, params \\ %{}, actor \\ @editor) do
    publication
    |> Ash.Changeset.for_update(action, params, actor: actor)
    |> Ash.update()
  end

  defp move!(publication, action, params \\ %{}) do
    {:ok, publication} = move(publication, action, params)
    publication
  end

  defp hours_from_now(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)

  defp reload(publication), do: Ash.get!(publication.__struct__, publication.id)

  defp run_until_settled(resource) do
    if Timeline.run_due(resource) > 0, do: run_until_settled(resource)
  end

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the publication edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = publication_for_posts(tmp_dir)
      subject = recipe.modules[Post]

      assert attributes(subject) == attributes(Post)
      assert actions(subject) == actions(Post)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Post)) == [:publication]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Post)) == [:published?]
    end

    test "is published while its publication is", %{tmp_dir: tmp_dir} do
      recipe = publication_for_posts(tmp_dir)
      post = post(recipe)
      {:ok, publication} = draft(recipe, post)

      assert Ash.load!(post, :published?).published? == false

      publication = move!(publication, :publish_now)
      assert Ash.load!(post, :published?).published?

      move!(publication, :unpublish)
      refute Ash.load!(post, :published?).published?
    end
  end

  test "creates a missing subject in the given domain and publishes against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @files
      |> generate([inspect(Page), "--domain", inspect(Domain)])
      |> compile(tmp_dir)

    page_module = recipe.modules[Page]

    publication_module =
      recipe.modules[AshWorkflowTest.RecipeFixtures.Publication.PagePublication]

    assert Ash.Resource.Info.data_layer(page_module) == Ash.DataLayer.Ets
    assert page_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    page = page_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    publication =
      publication_module
      |> Ash.Changeset.for_create(:create, %{subject_id: page.id})
      |> Ash.create!()

    assert publication.state == :draft
    assert Ash.load!(page, publication: :id).publication.id == publication.id
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Post), "--with-unpublish-at"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.publication", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  test "a subject has at most one publication", %{tmp_dir: tmp_dir} do
    recipe = publication_for_posts(tmp_dir)
    post = post(recipe)

    assert {:ok, _publication} = draft(recipe, post)
    assert {:error, %Ash.Error.Invalid{}} = draft(recipe, post)
  end

  describe "CanPublish" do
    # Each transition with the step it leaves, the step it enters and its params.
    @transitions [
      schedule: {:draft, :scheduled, %{publish_at: "in a day"}},
      publish_now: {:draft, :published, %{}},
      reschedule: {:scheduled, :scheduled, %{publish_at: "in a day"}},
      unschedule: {:scheduled, :draft, %{}},
      unpublish: {:published, :unpublished, %{}},
      republish: {:unpublished, :published, %{}}
    ]

    defp params(params) do
      Map.new(params, fn
        {key, "in a day"} -> {key, hours_from_now(24)}
        pair -> pair
      end)
    end

    # Moves a draft into `step` past the policy, as the application would
    # once it has decided who may.
    defp in_step(publication, :draft), do: publication

    defp in_step(publication, :scheduled),
      do: bypass(publication, :schedule, %{publish_at: hours_from_now(24)})

    defp in_step(publication, :published), do: bypass(publication, :publish_now)

    defp in_step(publication, :unpublished),
      do: publication |> in_step(:published) |> bypass(:unpublish)

    defp bypass(publication, action, params \\ %{}) do
      publication
      |> Ash.Changeset.for_update(action, params, authorize?: false)
      |> Ash.update!(authorize?: false)
    end

    test "denies every transition as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Post), "--with-unpublish-at"]
        |> generate()
        |> compile(tmp_dir)

      for {action, {step, _to, params}} <- @transitions do
        publication = recipe |> draft!() |> in_step(step)

        assert {:error, %Ash.Error.Forbidden{}} = move(publication, action, params(params)),
               "#{action} was not denied"

        assert reload(publication).state == step
      end

      assert Enum.any?(recipe.notices, &String.contains?(&1, "Nobody can schedule, publish"))
    end

    test "allows every transition once the application permits the actor", %{tmp_dir: tmp_dir} do
      recipe = publication_for_posts(tmp_dir)

      for {action, {step, to, params}} <- @transitions do
        publication = recipe |> draft!() |> in_step(step)

        assert {:error, %Ash.Error.Forbidden{}} =
                 move(publication, action, params(params), %{id: "reader", role: :reader})

        assert {:ok, %{state: ^to}} = move(publication, action, params(params))
      end
    end
  end

  describe "the transitions" do
    setup %{tmp_dir: tmp_dir}, do: %{recipe: publication_for_posts(tmp_dir)}

    test "schedule sets publish_at and unpublish_at", %{recipe: recipe} do
      publish_at = hours_from_now(24)
      unpublish_at = hours_from_now(48)

      assert %{state: :scheduled, publish_at: ^publish_at, unpublish_at: ^unpublish_at} =
               recipe
               |> draft!()
               |> move!(:schedule, %{publish_at: publish_at, unpublish_at: unpublish_at})
    end

    test "schedule requires a publish_at", %{recipe: recipe} do
      assert {:error, %Ash.Error.Invalid{}} = recipe |> draft!() |> move(:schedule)
    end

    test "schedule rejects an unpublish_at before publish_at", %{recipe: recipe} do
      assert {:error, %Ash.Error.Invalid{}} =
               recipe
               |> draft!()
               |> move(:schedule, %{
                 publish_at: hours_from_now(48),
                 unpublish_at: hours_from_now(24)
               })
    end

    test "reschedule moves publish_at and keeps unpublish_at", %{recipe: recipe} do
      unpublish_at = hours_from_now(72)

      scheduled =
        recipe
        |> draft!()
        |> move!(:schedule, %{publish_at: hours_from_now(24), unpublish_at: unpublish_at})

      publish_at = hours_from_now(48)

      assert %{state: :scheduled, publish_at: ^publish_at, unpublish_at: ^unpublish_at} =
               move!(scheduled, :reschedule, %{publish_at: publish_at})

      assert {:error, %Ash.Error.Invalid{}} =
               move(reload(scheduled), :reschedule, %{publish_at: hours_from_now(96)})
    end

    test "unschedule returns to draft and clears the schedule", %{recipe: recipe} do
      assert %{state: :draft, publish_at: nil, unpublish_at: nil} =
               recipe
               |> draft!()
               |> move!(:schedule, %{
                 publish_at: hours_from_now(24),
                 unpublish_at: hours_from_now(48)
               })
               |> move!(:unschedule)
    end

    test "publish_now publishes a draft or a scheduled publication", %{recipe: recipe} do
      assert %{state: :published} = recipe |> draft!() |> move!(:publish_now)

      unpublish_at = hours_from_now(48)

      assert %{state: :published, unpublish_at: ^unpublish_at} =
               recipe
               |> draft!()
               |> move!(:schedule, %{publish_at: hours_from_now(24), unpublish_at: unpublish_at})
               |> move!(:publish_now)
    end

    test "unpublish and republish move between published and unpublished", %{recipe: recipe} do
      unpublished = recipe |> draft!() |> move!(:publish_now) |> move!(:unpublish)
      assert unpublished.state == :unpublished

      unpublish_at = hours_from_now(24)

      assert %{state: :published, unpublish_at: ^unpublish_at} =
               move!(unpublished, :republish, %{unpublish_at: unpublish_at})

      assert %{state: :published, unpublish_at: nil} =
               reload(unpublished) |> move!(:unpublish) |> move!(:republish)
    end

    test "only the transitions in the diagram are allowed from each step", %{recipe: recipe} do
      draft = draft!(recipe)

      for action <- [:reschedule, :unschedule, :unpublish, :republish] do
        assert {:error, _error} = move(draft, action, %{publish_at: hours_from_now(1)})
      end

      published = move!(draft, :publish_now)
      assert {:error, _error} = move(published, :schedule, %{publish_at: hours_from_now(1)})
    end
  end

  describe "the deadlines" do
    setup %{tmp_dir: tmp_dir}, do: %{recipe: publication_for_posts(tmp_dir)}

    test "a scheduled publication is published once publish_at passes", %{recipe: recipe} do
      publication_module = recipe.modules[PostPublication]

      due = recipe |> draft!() |> move!(:schedule, %{publish_at: hours_from_now(-1)})
      later = recipe |> draft!() |> move!(:schedule, %{publish_at: hours_from_now(24)})

      assert Timeline.run_due(publication_module) == 1
      assert reload(due).state == :published
      assert reload(later).state == :scheduled
      assert Timeline.run_due(publication_module) == 0
    end

    test "a republished publication is unpublished once unpublish_at passes", %{recipe: recipe} do
      publication_module = recipe.modules[PostPublication]

      due =
        recipe
        |> draft!()
        |> move!(:publish_now)
        |> move!(:unpublish)
        |> move!(:republish, %{unpublish_at: hours_from_now(-1)})

      later = recipe |> draft!() |> move!(:publish_now)

      assert Timeline.run_due(publication_module) == 1
      assert reload(due).state == :unpublished
      assert reload(later).state == :published
    end

    test "a schedule whose publish_at and unpublish_at have passed publishes then unpublishes",
         %{recipe: recipe} do
      publication_module = recipe.modules[PostPublication]

      publication =
        recipe
        |> draft!()
        |> move!(:schedule, %{publish_at: hours_from_now(-2), unpublish_at: hours_from_now(-1)})

      run_until_settled(publication_module)
      assert reload(publication).state == :unpublished

      log =
        recipe.modules[PostPublicationTransition] |> Ash.read!() |> Enum.map(& &1.to_state)

      assert Enum.sort(log) == [:draft, :published, :scheduled, :unpublished]
    end

    test "a publication without unpublish_at stays published", %{recipe: recipe} do
      publication_module = recipe.modules[PostPublication]

      publication = recipe |> draft!() |> move!(:schedule, %{publish_at: hours_from_now(-1)})

      assert Timeline.run_due(publication_module) == 1
      assert %{state: :published, unpublish_at: nil} = reload(publication)
      assert Timeline.run_due(publication_module) == 0
    end

    test "a republished publication does not reuse an unpublish_at that has passed", %{
      recipe: recipe
    } do
      publication_module = recipe.modules[PostPublication]

      publication =
        recipe
        |> draft!()
        |> move!(:schedule, %{publish_at: hours_from_now(-2), unpublish_at: hours_from_now(-1)})

      run_until_settled(publication_module)

      republished = publication |> reload() |> move!(:republish)
      assert Timeline.run_due(publication_module) == 0
      assert reload(republished).state == :published
    end
  end

  describe "without --with-unpublish-at" do
    test "there is no unpublish_at and a publication stays published", %{tmp_dir: tmp_dir} do
      recipe = publication_for_posts(tmp_dir, [])
      publication_module = recipe.modules[PostPublication]

      assert step_names(publication_module) == [:draft, :scheduled, :published, :unpublished]
      refute Ash.Resource.Info.attribute(publication_module, :unpublish_at)

      timeouts =
        for step <- AshWorkflow.Info.steps(publication_module),
            timeout <- step.timeouts,
            do: {step.name, timeout.name}

      assert timeouts == [scheduled: :published]

      publication = recipe |> draft!() |> move!(:schedule, %{publish_at: hours_from_now(-1)})

      assert Timeline.run_due(publication_module) == 1
      assert reload(publication).state == :published
      assert Timeline.run_due(publication_module) == 0

      assert %{state: :draft, publish_at: nil} =
               recipe
               |> draft!()
               |> move!(:schedule, %{publish_at: hours_from_now(24)})
               |> move!(:unschedule)

      assert %{state: :published} =
               publication |> reload() |> move!(:unpublish) |> move!(:republish)
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
        "--with-unpublish-at"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketPublication: "postgres_ticket_publications",
          PostgresTicketPublicationTransition: "postgres_ticket_publications_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Post), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.publication", [inspect(Page)])

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
