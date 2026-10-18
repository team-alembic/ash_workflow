defmodule Mix.Tasks.AshWorkflow.Gen.TransitionLogTest do
  use AshWorkflow.RecipeCase, async: true

  alias AshWorkflowTest.RecipeFixtures.TransitionLog.PostgresTicket
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Ticket

  @fixtures "test/support/recipe_fixtures/transition_log"
  @ets_files ["#{@fixtures}/domain.ex", "#{@fixtures}/ticket.ex", "#{@fixtures}/reviewer.ex"]

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
    log |> Ash.read!() |> Enum.sort_by(& &1.occurred_at, DateTime)
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
      Reviewer
      |> Ash.Changeset.for_create(:create, %{name: "Ada"})
      |> Ash.create!()

    ticket |> open_ticket() |> Ash.update!(action: :close, actor: reviewer)

    assert [initial, close] = log_rows(log)
    assert initial.reviewer_id == nil
    assert close.reviewer_id == reviewer.id
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
end
