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

  test "renames references made through grouped, partial and nested-module aliases", %{
    tmp_dir: tmp_dir
  } do
    files = %{
      "lib/greeting/name.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Greeting.Name do
        def value, do: "Ada"
      end
      """,
      "lib/greeting/punctuation.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Greeting.Punctuation do
        def mark, do: "!"
      end
      """,
      "lib/greeting/greeter.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Greeting.Greeter do
        alias AshWorkflowTest.RecipeCaseFixtures.Greeting
        alias AshWorkflowTest.RecipeCaseFixtures.Greeting.{Name, Punctuation}

        defmodule Changes.Shout do
          def call(text), do: String.upcase(text)
        end

        def greet, do: Changes.Shout.call("hello " <> Name.value() <> Punctuation.mark())

        def name, do: Greeting.Name.value()
      end
      """
    }

    recipe = files |> recipe(Map.keys(files)) |> compile(tmp_dir)
    greeter = recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Greeting.Greeter]
    shout = recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Greeting.Greeter.Changes.Shout]

    assert greeter.greet() == "HELLO ADA!"
    assert greeter.name() == "Ada"
    assert Module.split(shout) == Module.split(greeter) ++ ["Changes", "Shout"]
    assert Code.ensure_loaded?(shout)
  end

  test "fails when a written file still references a renamed module", %{tmp_dir: tmp_dir} do
    files = %{
      "lib/lookup.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Lookup do
        def self, do: :"Elixir.AshWorkflowTest.RecipeCaseFixtures.Lookup"
      end
      """
    }

    assert_raise ExUnit.AssertionError,
                 ~r/lib\/lookup.ex still references AshWorkflowTest.RecipeCaseFixtures.Lookup/,
                 fn -> files |> recipe(Map.keys(files)) |> compile(tmp_dir) end
  end
end
