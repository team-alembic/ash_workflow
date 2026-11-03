defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLogTest do
  use AshWorkflow.RecipeCase, async: true

  alias Ash.Domain.Igniter, as: DomainIgniter

  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Auditor
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Ticket

  @fixtures "test/support/recipe_fixtures/transition_log"
  @ets_files Enum.map(~w(domain ticket reviewer auditor), &"#{@fixtures}/#{&1}.ex")

  defp generate(files, argv) do
    files
    |> project()
    |> run_task("ash_workflow.gen.transition_log", argv)
  end

  defp open_ticket(ticket) do
    ticket
    |> Ash.Changeset.for_create(:create, %{title: "Broken printer"})
    |> Ash.create!()
  end

  defp log_rows(log) do
    log |> Ash.Query.sort(occurred_at: :asc, id: :asc) |> Ash.read!()
  end

  test "the generated log resource records each transition of the workflow", %{tmp_dir: tmp_dir} do
    recipe = @ets_files |> generate([inspect(Ticket)]) |> compile(tmp_dir)

    ticket = recipe.modules[Ticket]
    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.TicketTransition]

    assert AshWorkflow.Info.transition_log(ticket).resource == log
    assert log in Ash.Domain.Info.resources(Ash.Resource.Info.domain(ticket))

    record = ticket |> open_ticket() |> Ash.update!(action: :close)

    assert [initial, close] = log_rows(log)
    assert {initial.from_state, initial.to_state, initial.triggered_by} == {nil, :open, :initial}
    assert {close.from_state, close.to_state, close.transition_name} == {:open, :closed, :close}
    assert close.triggered_by == :manual
    assert close.workflow_id == record.id
  end

  test "the generated log resource uses the workflow's ETS data layer and domain" do
    recipe = generate(@ets_files, [inspect(Ticket)])

    content =
      source!(recipe, "lib/ash_workflow_test/recipe_fixtures/transition_log/ticket_transition.ex")

    assert content =~ "domain: AshWorkflowTest.RecipeFixtures.TransitionLog.Domain"
    assert content =~ "data_layer: Ash.DataLayer.Ets"
    assert content =~ "belongs_to(:undoes, __MODULE__"

    assert Enum.any?(
             recipe.notices,
             &String.contains?(&1, "mix ash_workflow.backfill_transition_log")
           )
  end

  test "respects --log-module", %{tmp_dir: tmp_dir} do
    recipe =
      @ets_files
      |> generate([
        inspect(Ticket),
        "--log-module",
        "AshWorkflowTest.RecipeFixtures.TransitionLog.CustomLog"
      ])
      |> compile(tmp_dir)

    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.CustomLog]

    assert AshWorkflow.Info.transition_log(recipe.modules[Ticket]).resource == log

    recipe.modules[Ticket] |> open_ticket() |> Ash.update!(action: :close)

    assert [%{to_state: :open}, %{to_state: :closed}] = log_rows(log)
  end

  test "--actor records the actor on each row", %{tmp_dir: tmp_dir} do
    recipe =
      @ets_files
      |> generate([inspect(Ticket), "--actor", inspect(Reviewer)])
      |> compile(tmp_dir)

    ticket = recipe.modules[Ticket]
    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.TicketTransition]

    reviewer =
      recipe.modules[Reviewer]
      |> Ash.Changeset.for_create(:create, %{name: "Ada"})
      |> Ash.create!()

    ticket |> open_ticket() |> Ash.update!(action: :close, actor: reviewer)

    assert [initial, close] = log_rows(log)
    assert initial.reviewer_id == nil
    assert close.reviewer_id == reviewer.id
  end

  test "--actor types the actor foreign key after the actor's primary key", %{tmp_dir: tmp_dir} do
    recipe =
      @ets_files
      |> generate([inspect(Ticket), "--actor", inspect(Auditor)])
      |> compile(tmp_dir)

    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.TicketTransition]
    assert Ash.Resource.Info.attribute(log, :auditor_id).type == Ash.Type.Integer

    auditor =
      recipe.modules[Auditor] |> Ash.Changeset.for_create(:create, %{id: 7}) |> Ash.create!()

    recipe.modules[Ticket] |> open_ticket() |> Ash.update!(action: :close, actor: auditor)

    assert [%{auditor_id: nil}, %{auditor_id: 7}] = log_rows(log)
  end

  test "generates a Postgres-backed log resource reusing the workflow's table and repo", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      ["#{@fixtures}/postgres_domain.ex", "#{@fixtures}/postgres_ticket.ex"]
      |> generate([inspect(PostgresTicket)])
      |> compile(tmp_dir)

    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicketTransition]

    assert AshPostgres.DataLayer.Info.repo(log) == AshWorkflowTest.Repo
    assert AshPostgres.DataLayer.Info.table(log) == "recipe_fixture_tickets_transitions"

    assert [%{fields: [:workflow_id, :occurred_at]}] =
             AshPostgres.DataLayer.Info.custom_indexes(log)
  end

  test "logs a workflow generated earlier in the same run, before it has compiled", %{
    tmp_dir: tmp_dir
  } do
    workflow = AshWorkflowTest.RecipeFixtures.TransitionLog.Draft

    recipe =
      @ets_files
      |> project()
      |> Igniter.Project.Module.create_module(workflow, """
      use Ash.Resource,
        domain: AshWorkflowTest.RecipeFixtures.TransitionLog.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow, AshOban]

      workflow do
        step :drafting do
          transition :publish, to: :published
        end

        step :published, terminal: true
      end

      actions do
        defaults [:read, :create]
      end

      attributes do
        uuid_v7_primary_key :id
      end
      """)
      |> DomainIgniter.add_resource_reference(
        AshWorkflowTest.RecipeFixtures.TransitionLog.Domain,
        workflow
      )
      |> run_task("ash_workflow.gen.transition_log", [inspect(workflow)])
      |> compile(tmp_dir)

    log = recipe.modules[AshWorkflowTest.RecipeFixtures.TransitionLog.DraftTransition]

    recipe.modules[workflow]
    |> Ash.Changeset.for_create(:create, %{})
    |> Ash.create!()
    |> Ash.update!(action: :publish)

    assert [%{to_state: :drafting}, %{to_state: :published}] = log_rows(log)
  end

  test "warns instead of duplicating when a transition_log is already configured" do
    recipe =
      generate(
        [
          "test/support/workflows/logged_workflow.ex",
          "test/support/workflows/logged_transition.ex",
          "test/support/reviewer.ex",
          "test/support/domain.ex"
        ],
        ["AshWorkflowTest.LoggedWorkflow"]
      )

    assert Enum.any?(recipe.warnings, &String.contains?(&1, "already has a `transition_log`"))
    refute Map.has_key?(recipe.changed, "test/support/workflows/logged_workflow.ex")
  end

  test "reports an issue for a plain module that does not use AshWorkflow" do
    igniter =
      @ets_files
      |> project()
      |> Igniter.compose_task("ash_workflow.gen.transition_log", ["String"])

    assert Enum.any?(
             igniter.issues,
             &String.contains?(&1, "does not use the AshWorkflow extension")
           )
  end

  test "reports an issue for a workflow on disk that does not compile" do
    workflow = AshWorkflowTest.RecipeFixtures.TransitionLog.Broken

    igniter =
      Igniter.Test.test_project(
        app_name: :ash_workflow,
        files:
          @ets_files
          |> Map.new(&{&1, File.read!(&1)})
          |> Map.put("lib/broken.ex", """
          defmodule #{inspect(workflow)} do
            use Ash.Resource,
              domain: AshWorkflowTest.RecipeFixtures.TransitionLog.Domain,
              extensions: [AshWorkflow]

            workflow do
              step :drafting, terminal: true
            end

            attributes do
              uuid_v7_primary_key :id
              attribute :title, :not_a_type
            end
          end
          """)
      )
      |> Igniter.compose_task("ash_workflow.gen.transition_log", [inspect(workflow)])

    assert Enum.any?(igniter.issues, &String.contains?(&1, "Could not load #{inspect(workflow)}"))
    assert Enum.any?(igniter.issues, &String.contains?(&1, "must already exist and compile"))
  end
end
