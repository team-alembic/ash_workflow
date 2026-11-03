defmodule AshWorkflow.RecipeCaseTest do
  use AshWorkflow.RecipeCase, async: true

  alias Ash.Resource.Info
  alias AshWorkflow.RecipeCase
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Domain
  alias AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer
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
      Map.new(
        ~w(domain reviewer auditor) |> Enum.map(&"#{@fixtures}/#{&1}.ex"),
        &{&1, File.read!(&1)}
      )

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

  test "fails when generated code references a fixture the project left out", %{
    tmp_dir: tmp_dir
  } do
    recipe =
      ["#{@fixtures}/domain.ex", @ticket]
      |> project()
      |> run_task("ash_workflow.gen.transition_log", [
        inspect(Ticket),
        "--actor",
        inspect(Reviewer)
      ])

    assert_raise ExUnit.AssertionError,
                 ~r/references AshWorkflowTest.RecipeFixtures.TransitionLog.Reviewer, which the project does not include/,
                 fn -> compile(recipe, tmp_dir) end
  end

  test "renames a module defined as __MODULE__.Child and the references to it", %{
    tmp_dir: tmp_dir
  } do
    files = %{
      "lib/parent.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Parent do
        defmodule __MODULE__.Child do
          def value, do: :child
        end
      end
      """,
      "lib/caller.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Caller do
        def value, do: AshWorkflowTest.RecipeCaseFixtures.Parent.Child.value()
      end
      """
    }

    recipe = files |> recipe(Map.keys(files)) |> compile(tmp_dir)
    child = recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Parent.Child]

    assert Module.split(child) ==
             Module.split(recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Parent]) ++ ["Child"]

    assert recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Caller].value() == :child
  end

  test "fails when a generated implementation of a consolidated protocol never runs", %{
    tmp_dir: tmp_dir
  } do
    files = %{
      "lib/label.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Label do
        defstruct [:text]

        defimpl String.Chars do
          def to_string(label), do: label.text
        end
      end
      """
    }

    assert_raise ExUnit.AssertionError,
                 ~r/String.Chars protocol has already been consolidated/,
                 fn -> files |> recipe(Map.keys(files)) |> compile(tmp_dir) end
  end

  test "a renamed ETS resource can enter an automatic step under the Oban scheduler", %{
    tmp_dir: tmp_dir
  } do
    files = %{
      "lib/job/domain.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Job.Domain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource AshWorkflowTest.RecipeCaseFixtures.Job
        end
      end
      """,
      "lib/job.ex" => """
      defmodule AshWorkflowTest.RecipeCaseFixtures.Job do
        use Ash.Resource,
          domain: AshWorkflowTest.RecipeCaseFixtures.Job.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :queued do
            action :run
            on_success :done
          end

          step :done, terminal: true
        end

        actions do
          defaults [:read, create: []]

          update :run do
            require_atomic? false
          end
        end

        attributes do
          uuid_v7_primary_key :id
        end
      end
      """
    }

    recipe = files |> recipe(Map.keys(files)) |> compile(tmp_dir)
    job = recipe.modules[AshWorkflowTest.RecipeCaseFixtures.Job]

    assert %{state: :queued} = job |> Ash.Changeset.for_create(:create) |> Ash.create!()
  end
end
