defmodule Mix.Tasks.AshWorkflow.Gen.ReviewTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflow.Scheduler.Precise.Timeline
  alias AshWorkflowTest.RecipeFixtures.Review.Article
  alias AshWorkflowTest.RecipeFixtures.Review.ArticleReview
  alias AshWorkflowTest.RecipeFixtures.Review.ArticleReviewDecision
  alias AshWorkflowTest.RecipeFixtures.Review.ArticleReviewTransition
  alias AshWorkflowTest.RecipeFixtures.Review.Domain
  alias AshWorkflowTest.RecipeFixtures.Review.Note
  alias AshWorkflowTest.RecipeFixtures.Review.Post
  alias AshWorkflowTest.RecipeFixtures.Review.User

  @fixtures "test/support/recipe_fixtures/review"
  @domain_files Enum.map(~w(domain user note), &"#{@fixtures}/#{&1}.ex")
  @files @domain_files ++ ["#{@fixtures}/article.ex"]
  @checks "lib/ash_workflow_test/recipe_fixtures/review/article_review/checks"
  @deny_all "def match?(_actor, _context, _opts), do: false"

  defp generate(files \\ @files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.review", argv)
  end

  defp review_for_articles(tmp_dir, argv \\ []) do
    [inspect(Article), "--reviewer", inspect(User) | argv]
    |> generate()
    |> allow_requesters()
    |> allow_reviewers()
    |> compile(tmp_dir)
  end

  # What an application does once it has generated the recipe: fill in
  # CanRequest and CanReview. Here any actor may open a review, and anyone
  # with the :reviewer role may review.
  defp allow_requesters(recipe, checks \\ @checks) do
    edit_source(recipe, "#{checks}/can_request.ex", fn source ->
      String.replace(source, @deny_all, "def match?(actor, _context, _opts), do: is_map(actor)")
    end)
  end

  defp allow_reviewers(recipe) do
    edit_source(recipe, "#{@checks}/can_review.ex", fn source ->
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

  defp user(recipe, role \\ :reviewer) do
    recipe.modules[User]
    |> Ash.Changeset.for_create(:create, %{name: "#{role}", role: role})
    |> Ash.create!()
  end

  defp article(recipe) do
    recipe.modules[Article]
    |> Ash.Changeset.for_create(:create, %{title: "Release notes"})
    |> Ash.create!()
  end

  defp request(recipe, subject, requester) do
    recipe.modules[ArticleReview]
    |> Ash.Changeset.for_create(:request, %{subject_id: subject.id}, actor: requester)
    |> Ash.create!()
  end

  defp submitted_days_ago(recipe, subject, requester, days) do
    recipe.modules[ArticleReview]
    |> Ash.Changeset.for_create(:request, %{subject_id: subject.id}, actor: requester)
    |> Ash.Changeset.force_change_attribute(
      :submitted_at,
      DateTime.add(DateTime.utc_now(), -days, :day)
    )
    |> Ash.create!()
  end

  defp act(review, action, actor, input \\ %{}) do
    review
    |> Ash.Changeset.for_update(action, input, actor: actor)
    |> Ash.update()
  end

  defp request_changes(review, actor),
    do: act(review, :request_changes, actor, %{comment: "Cite the source"})

  defp reload(review), do: Ash.get!(review.__struct__, review.id)

  defp step_names(resource), do: resource |> AshWorkflow.Info.steps() |> Enum.map(& &1.name)

  describe "an existing subject" do
    test "keeps its own attributes and actions and gains only the three review edits", %{
      tmp_dir: tmp_dir
    } do
      recipe = review_for_articles(tmp_dir)
      subject = recipe.modules[Article]

      assert attributes(subject) == attributes(Article)
      assert actions(subject) == actions(Article)

      assert names(Ash.Resource.Info.relationships(subject)) --
               names(Ash.Resource.Info.relationships(Article)) == [:reviews, :latest_review]

      assert names(Ash.Resource.Info.calculations(subject)) --
               names(Ash.Resource.Info.calculations(Article)) == [:review_approved?]
    end

    test "is not review approved, rather than nil, without a review", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)

      assert Ash.load!(article(recipe), :review_approved?).review_approved? == false
    end

    test "is review approved once its latest review is", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      article = article(recipe)

      review = request(recipe, article, user(recipe, :author))
      refute Ash.load!(article, :review_approved?).review_approved?

      assert {:ok, %{state: :approved}} = act(review, :approve, user(recipe))
      assert Ash.load!(article, :review_approved?).review_approved?

      request(recipe, article, user(recipe, :author))
      refute Ash.load!(article, :review_approved?).review_approved?
    end
  end

  test "creates a missing subject in the given domain and reviews against it", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      @domain_files
      |> generate([inspect(Post), "--reviewer", inspect(User), "--domain", inspect(Domain)])
      |> allow_requesters("lib/ash_workflow_test/recipe_fixtures/review/post_review/checks")
      |> compile(tmp_dir)

    post_module = recipe.modules[Post]
    review_module = recipe.modules[AshWorkflowTest.RecipeFixtures.Review.PostReview]

    assert Ash.Resource.Info.data_layer(post_module) == Ash.DataLayer.Ets
    assert post_module in Ash.Domain.Info.resources(recipe.modules[Domain])

    post = post_module |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    review =
      review_module
      |> Ash.Changeset.for_create(:request, %{subject_id: post.id}, actor: user(recipe, :author))
      |> Ash.create!()

    assert {review.state, review.round} == {:in_review, 1}
    assert Ash.load!(post, latest_review: :id).latest_review.id == review.id
    assert Ash.Resource.Info.attribute(review_module, :subject_id).type == Ash.Type.UUIDv7
  end

  test "foreign keys take the type of the subject's and reviewer's primary keys", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      [inspect(Note), "--reviewer", inspect(User)]
      |> generate()
      |> compile(tmp_dir)

    review = recipe.modules[AshWorkflowTest.RecipeFixtures.Review.NoteReview]
    decision = recipe.modules[AshWorkflowTest.RecipeFixtures.Review.NoteReviewDecision]

    assert Ash.Resource.Info.attribute(review, :subject_id).type == Ash.Type.Integer
    assert Ash.Resource.Info.attribute(review, :requested_by_id).type == Ash.Type.UUIDv7
    assert Ash.Resource.Info.attribute(decision, :reviewer_id).type == Ash.Type.UUIDv7
  end

  test "running the task a second time changes nothing" do
    argv = [inspect(Article), "--reviewer", inspect(User), "--overdue-after", "3d"]
    first = generate(argv)
    second = run_task(first.igniter, "ash_workflow.gen.review", argv)

    assert second.changed == %{}
    assert second.warnings == []
  end

  test "warns and leaves an existing :reviews relationship to another resource" do
    article =
      "#{@fixtures}/article.ex"
      |> File.read!()
      |> String.replace(
        "  attributes do",
        "  relationships do\n    has_many :reviews, #{inspect(Note)}\n  end\n\n  attributes do"
      )

    recipe =
      Igniter.Test.test_project(
        app_name: :ash_workflow,
        files:
          @files
          |> Map.new(&{&1, File.read!(&1)})
          |> Map.put("#{@fixtures}/article.ex", article)
      )
      |> run_task("ash_workflow.gen.review", [inspect(Article), "--reviewer", inspect(User)])

    assert [warning] = recipe.warnings
    assert warning =~ "#{inspect(Article)} already has a relationship named :reviews"
    assert warning =~ "has_many :reviews, #{inspect(ArticleReview)}"

    source = source!(recipe, "#{@fixtures}/article.ex")
    assert source =~ "has_many(:reviews, #{inspect(Note)})"
    refute source =~ "has_many :reviews, #{inspect(ArticleReview)}"
    assert source =~ "has_one :latest_review, #{inspect(ArticleReview)}"
    assert source =~ "calculate(:review_approved?, :boolean, expr(latest_review.state"
  end

  describe "CanRequest" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Article), "--reviewer", inspect(User)]
        |> generate()
        |> allow_reviewers()
        |> compile(tmp_dir)

      result =
        recipe.modules[ArticleReview]
        |> Ash.Changeset.for_create(:request, %{subject_id: article(recipe).id},
          actor: user(recipe, :author)
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
      assert Ash.read!(recipe.modules[ArticleReview]) == []
      assert Enum.any?(recipe.notices, &String.contains?(&1, "Nobody can request or review yet"))
    end

    test "lets an actor open a review once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)

      assert %{state: :in_review} = request(recipe, article(recipe), user(recipe, :author))
    end
  end

  describe "CanReview" do
    test "denies everyone as generated", %{tmp_dir: tmp_dir} do
      recipe =
        [inspect(Article), "--reviewer", inspect(User)]
        |> generate()
        |> allow_requesters()
        |> compile(tmp_dir)

      review = request(recipe, article(recipe), user(recipe, :author))

      assert {:error, %Ash.Error.Forbidden{}} = request_changes(review, user(recipe))
      assert {:error, %Ash.Error.Forbidden{}} = act(review, :approve, user(recipe))
      assert {:error, %Ash.Error.Forbidden{}} = act(review, :reject, user(recipe))
      assert reload(review).state == :in_review
    end

    test "lets a reviewer decide once the application permits them", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      review = request(recipe, article(recipe), user(recipe, :author))

      assert {:error, %Ash.Error.Forbidden{}} = act(review, :approve, user(recipe, :author))
      assert {:ok, %{state: :approved}} = act(review, :approve, user(recipe))
    end

    test "the requester cannot review their own work", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      requester = user(recipe)
      review = request(recipe, article(recipe), requester)

      assert {:error, %Ash.Error.Forbidden{}} = request_changes(review, requester)
      assert {:error, %Ash.Error.Forbidden{}} = act(review, :approve, requester)
      assert {:error, %Ash.Error.Forbidden{}} = act(review, :reject, requester)
    end
  end

  describe "the review loop" do
    test "a review sent back and resubmitted twice is approved in round three", %{
      tmp_dir: tmp_dir
    } do
      recipe = review_for_articles(tmp_dir)
      requester = user(recipe, :author)
      reviewer = user(recipe)
      review = request(recipe, article(recipe), requester)

      assert {:ok, %{state: :changes_requested, round: 1} = review} =
               request_changes(review, reviewer)

      assert {:ok, %{state: :in_review, round: 2} = review} = act(review, :resubmit, requester)

      assert {:ok, %{state: :changes_requested} = review} = request_changes(review, reviewer)
      assert {:ok, %{state: :in_review, round: 3} = review} = act(review, :resubmit, requester)

      assert {:ok, %{state: :approved, round: 3}} =
               act(review, :approve, reviewer, %{comment: "Ship it"})

      decisions =
        recipe.modules[ArticleReviewDecision]
        |> Ash.read!()
        |> Enum.sort_by(& &1.round)
        |> Enum.map(&{&1.round, &1.decision, &1.comment, &1.reviewer_id})

      assert decisions == [
               {1, :changes_requested, "Cite the source", reviewer.id},
               {2, :changes_requested, "Cite the source", reviewer.id},
               {3, :approved, "Ship it", reviewer.id}
             ]

      log =
        recipe.modules[ArticleReviewTransition] |> Ash.read!() |> Enum.map(& &1.to_state)

      assert Enum.frequencies(log) == %{in_review: 3, changes_requested: 2, approved: 1}
    end

    test "a reviewer can reject after a resubmission", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      requester = user(recipe, :author)
      review = request(recipe, article(recipe), requester)

      {:ok, review} = request_changes(review, user(recipe))
      {:ok, review} = act(review, :resubmit, requester)

      assert {:ok, %{state: :rejected, round: 2}} = act(review, :reject, user(recipe))
    end

    test "requesting changes needs a comment", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      review = request(recipe, article(recipe), user(recipe, :author))

      assert {:error, %Ash.Error.Invalid{}} = act(review, :request_changes, user(recipe))
      assert reload(review).state == :in_review
    end

    test "only the requester can resubmit", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      requester = user(recipe, :author)
      review = request(recipe, article(recipe), requester)
      {:ok, review} = request_changes(review, user(recipe))

      assert {:error, %Ash.Error.Forbidden{}} = act(review, :resubmit, user(recipe))
      assert {:error, %Ash.Error.Forbidden{}} = act(review, :resubmit, user(recipe, :author))
      assert {:ok, %{state: :in_review}} = act(review, :resubmit, requester)
    end

    test "a review in review cannot be resubmitted", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      requester = user(recipe, :author)
      review = request(recipe, article(recipe), requester)

      assert {:error, _error} = act(review, :resubmit, requester)
      assert reload(review).round == 1
    end
  end

  describe "--overdue-after" do
    test "moves a review nobody has decided to overdue once the deadline passes", %{
      tmp_dir: tmp_dir
    } do
      recipe = review_for_articles(tmp_dir, ["--overdue-after", "3d"])
      review_module = recipe.modules[ArticleReview]
      article = article(recipe)

      fresh = request(recipe, article, user(recipe, :author))
      late = submitted_days_ago(recipe, article, user(recipe, :author), 4)

      assert Timeline.run_due(review_module) == 1
      assert reload(fresh).state == :in_review
      assert reload(late).state == :overdue
    end

    test "an overdue review can still be decided", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir, ["--overdue-after", "3d"])
      review_module = recipe.modules[ArticleReview]
      article = article(recipe)

      to_send_back = submitted_days_ago(recipe, article, user(recipe, :author), 4)
      to_approve = submitted_days_ago(recipe, article, user(recipe, :author), 4)
      to_reject = submitted_days_ago(recipe, article, user(recipe, :author), 4)

      assert Timeline.run_due(review_module) == 3

      assert {:ok, %{state: :changes_requested}} =
               to_send_back |> reload() |> request_changes(user(recipe))

      assert {:ok, %{state: :approved}} = to_approve |> reload() |> act(:approve, user(recipe))
      assert {:ok, %{state: :rejected}} = to_reject |> reload() |> act(:reject, user(recipe))
    end

    test "a resubmission starts a new review clock", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir, ["--overdue-after", "3d"])
      review_module = recipe.modules[ArticleReview]
      requester = user(recipe, :author)

      review = submitted_days_ago(recipe, article(recipe), requester, 4)
      assert Timeline.run_due(review_module) == 1

      {:ok, review} = review |> reload() |> request_changes(user(recipe))
      {:ok, review} = act(review, :resubmit, requester)

      assert Timeline.run_due(review_module) == 0
      assert {reload(review).state, reload(review).round} == {:in_review, 2}
    end

    test "a review waiting on changes does not go overdue", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir, ["--overdue-after", "3d"])
      review = submitted_days_ago(recipe, article(recipe), user(recipe, :author), 4)
      {:ok, review} = request_changes(review, user(recipe))

      assert Timeline.run_due(recipe.modules[ArticleReview]) == 0
      assert reload(review).state == :changes_requested
    end

    test "without it, no overdue step is generated", %{tmp_dir: tmp_dir} do
      recipe = review_for_articles(tmp_dir)
      review_module = recipe.modules[ArticleReview]

      assert step_names(review_module) == [:in_review, :changes_requested, :approved, :rejected]
      assert AshWorkflow.Info.scheduled_work(review_module) == []
    end

    test "reports an issue for a duration it cannot parse" do
      igniter =
        @files
        |> project()
        |> Igniter.compose_task("ash_workflow.gen.review", [
          inspect(Article),
          "--reviewer",
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
        "--reviewer",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer"
      ])
      |> compile(tmp_dir)

    for {module, table} <- [
          PostgresTicketReview: "postgres_ticket_reviews",
          PostgresTicketReviewDecision: "postgres_ticket_review_decisions",
          PostgresTicketReviewTransition: "postgres_ticket_reviews_transitions"
        ] do
      resource =
        recipe.modules[Module.concat(AshWorkflowTest.RecipeFixtures.TransitionLog, module)]

      assert AshPostgres.DataLayer.Info.repo(resource) == AshWorkflowTest.Repo
      assert AshPostgres.DataLayer.Info.table(resource) == table
    end
  end

  test "--no-transition-log generates no transition log" do
    recipe = generate([inspect(Article), "--reviewer", inspect(User), "--no-transition-log"])

    refute Enum.any?(Map.keys(recipe.changed), &String.ends_with?(&1, "_transition.ex"))
  end

  test "reports an issue for a missing subject without --domain" do
    igniter =
      @domain_files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.review", [
        inspect(Post),
        "--reviewer",
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
