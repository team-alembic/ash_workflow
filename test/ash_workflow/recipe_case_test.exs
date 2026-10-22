defmodule AshWorkflow.RecipeCaseTest do
  use AshWorkflow.RecipeCase, async: true

  alias Ash.Resource.Info
  alias AshWorkflow.RecipeCase
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Domain
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Ticket

  @fixtures "test/support/recipe_fixtures/transition_log"
  @ticket "#{@fixtures}/ticket.ex"

  defp recipe(files, changed_paths) do
    %RecipeCase{
      igniter: Igniter.Test.test_project(app_name: :ash_workflow, files: files),
      changed: Map.take(files, changed_paths)
    }
  end

  test "a subject edited without its domain is compiled against the renamed domain", %{
    tmp_dir: tmp_dir
  } do
    ticket_source =
      @ticket
      |> File.read!()
      |> String.replace("    create :create do", """
          update :retitle do
            accept [:title]
          end

          create :create do
      """)

    files =
      Map.new(["#{@fixtures}/domain.ex", "#{@fixtures}/reviewer.ex"], &{&1, File.read!(&1)})

    recipe = files |> Map.put(@ticket, ticket_source) |> recipe([@ticket]) |> compile(tmp_dir)
    ticket = recipe.modules[Ticket]

    assert Info.domain(ticket) == recipe.modules[Domain]

    record =
      ticket
      |> Ash.Changeset.for_create(:create, %{title: "Broken printer"})
      |> Ash.create!()
      |> Ash.Changeset.for_update(:retitle, %{title: "Broken scanner"})
      |> Ash.update!()

    assert record.title == "Broken scanner"
  end
end
