defmodule AshWorkflow.InitialStepTest do
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  alias AshStateMachine.Info, as: SMInfo
  alias AshWorkflow.Charts.Graph
  alias AshWorkflow.Charts.Mermaid
  alias AshWorkflow.Info

  describe "initial: true flag" do
    test "step with initial: true becomes the initial state, overriding declaration order" do
      # :draft is declared first but :review has initial: true
      assert {:ok, :review} =
               SMInfo.state_machine_default_initial_state(AshWorkflowTest.InitialFlagWorkflow)
    end

    test "workflow starts in the initial step" do
      {:ok, record} = AshWorkflowTest.InitialFlagWorkflow.create(%{title: "test"})
      assert record.state == :review
    end
  end

  describe "several initial steps" do
    alias AshWorkflowTest.MultipleInitialWorkflow

    test "every marked step is an initial state, and the first is the default" do
      assert {:ok, [:start_one, :start_two]} =
               SMInfo.state_machine_initial_states(MultipleInitialWorkflow)

      assert {:ok, :start_one} =
               SMInfo.state_machine_default_initial_state(MultipleInitialWorkflow)
    end

    test "a create that sets no state starts in the default initial step" do
      {:ok, record} = MultipleInitialWorkflow.create(%{title: "test"})
      assert record.state == :start_one
    end

    test "a create can start in another initial step with transition_state" do
      {:ok, record} = MultipleInitialWorkflow.create_at_start_two(%{title: "test"})
      assert record.state == :start_two

      {:ok, finished} = Ash.update(record, %{}, action: :finish)
      assert finished.state == :done
    end

    test "Info lists every initial step and keeps the first as the default" do
      assert Enum.map(Info.initial_steps(MultipleInitialWorkflow), & &1.name) ==
               [:start_one, :start_two]

      assert Info.initial_step(MultipleInitialWorkflow).name == :start_one
    end

    test "workflow_graph marks every initial step" do
      graph = Info.workflow_graph(MultipleInitialWorkflow)

      assert graph[:start_one].initial
      assert graph[:start_two].initial
      refute graph[:done].initial
    end

    test "the Mermaid chart draws a start edge to every initial step" do
      output =
        MultipleInitialWorkflow
        |> Graph.build()
        |> Mermaid.render([])
        |> IO.iodata_to_binary()

      assert output =~ "[*] --> step_start_one"
      assert output =~ "[*] --> step_start_two"
    end
  end

  describe "verifier" do
    test "rejects a step no initial step reaches" do
      assert_dsl_error(
        """
        defmodule StrandedFromInitialsWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :step_a do
              initial true
              transition :finish, to: :done
            end

            step :step_b do
              initial true
              transition :finish, to: :done
            end

            step :stranded do
              transition :finish, to: :done
            end

            step :done, terminal: true
          end

          actions do
            create :create_at_b do
              change transition_state(:step_b)
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/not reachable from any initial step \[:step_a, :step_b\]: \[:stranded\]\. No step leads into :stranded\. Mark it `initial true`/
      )
    end

    test "rejects a create that starts records in a step that is not initial" do
      assert_dsl_error(
        """
        defmodule CreateIntoNonInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :draft do
              transition :submit, to: :review
            end

            step :review do
              transition :approve, to: :done
            end

            step :done, terminal: true
          end

          actions do
            create :create_in_review do
              change transition_state(:review)
            end
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/Create action :create_in_review starts records in :review, which is not an initial step/
      )
    end

    test "rejects an upserting create that names its starting step" do
      assert_dsl_error(
        """
        defmodule UpsertIntoInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :start_one do
              initial true
              transition :finish, to: :done
            end

            step :start_two do
              initial true
              transition :finish, to: :done
            end

            step :done, terminal: true
          end

          identities do
            identity :unique_key, [:key], pre_check_with: AshWorkflowTest.Domain
          end

          actions do
            create :upsert_at_two do
              accept [:key]
              upsert? true
              upsert_identity :unique_key
              change transition_state(:start_two)
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :key, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/Create action :upsert_at_two upserts and calls transition_state\(:start_two\)/
      )
    end

    test "rejects a later initial step that no create starts records in" do
      assert_dsl_error(
        """
        defmodule UnstartedInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :draft do
              initial true
              transition :submit, to: :review
            end

            step :review do
              initial true
              transition :approve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/Step :review is marked `initial true`, but no create action starts a record in it/
      )
    end

    test "accepts a create whose starting step comes from an argument" do
      defmodule ArgumentStartWorkflow do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban],
          validate_domain_inclusion?: false

        workflow do
          step :start_one do
            initial true
            transition :finish, to: :done
          end

          step :start_two do
            initial true
            transition :finish, to: :done
          end

          step :done, terminal: true
        end

        actions do
          create :create_at do
            argument :start, :atom, allow_nil?: false
            change transition_state(arg(:start))
          end
        end

        attributes do
          uuid_v7_primary_key :id
        end
      end

      assert {:ok, [:start_one, :start_two]} =
               SMInfo.state_machine_initial_states(ArgumentStartWorkflow)
    end

    test "rejects a terminal step marked initial: true" do
      assert_dsl_error(
        """
        defmodule TerminalInitialWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :review do
              transition :approve, to: :done
            end

            step :done, terminal: true, initial: true
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false
          end
        end
        """,
        ~r/Terminal step .* cannot have initial: true/
      )
    end
  end
end
