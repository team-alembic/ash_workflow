defmodule AshWorkflow.Verifiers.ValidateTransitionLogTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  describe "transition log validation" do
    test "rejects a log resource missing required :atom attributes" do
      assert_dsl_error(
        """
        defmodule MissingAttributesLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :occurred_at, :utc_datetime_usec, public?: true
          end
        end

        defmodule MissingAttributesLogWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log MissingAttributesLog

            step :waiting do
              transition :resolve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/missing required :atom attributes/
      )
    end

    test "rejects a log resource whose occurred_at is not a datetime" do
      assert_dsl_error(
        """
        defmodule BadOccurredAtLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :from_state, :atom, public?: true
            attribute :to_state, :atom, public?: true
            attribute :transition_name, :atom, public?: true
            attribute :triggered_by, :atom, public?: true
            attribute :occurred_at, :integer, public?: true
          end
        end

        defmodule BadOccurredAtLogWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log BadOccurredAtLog

            step :waiting do
              transition :resolve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/must define an `occurred_at` attribute with a datetime type/
      )
    end

    test "rejects a log resource with no belongs_to relationship back to the workflow" do
      assert_dsl_error(
        """
        defmodule NoBelongsToLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :from_state, :atom, public?: true
            attribute :to_state, :atom, public?: true
            attribute :transition_name, :atom, public?: true
            attribute :triggered_by, :atom, public?: true
            attribute :occurred_at, :utc_datetime_usec, public?: true
          end
        end

        defmodule NoBelongsToLogWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log NoBelongsToLog

            step :waiting do
              transition :resolve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/has no `belongs_to` relationship back to/
      )
    end

    test "rejects a transition_log naming a module that does not exist" do
      assert_dsl_error(
        """
        defmodule NonexistentLogWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log Nonexistent.Log.Module.That.Does.Not.Exist

            step :waiting do
              transition :resolve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/could not be compiled/
      )
    end

    test "rejects a belongs_to_actor with no matching relationship on the log resource" do
      assert_dsl_error(
        """
        defmodule MismatchedActorLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :from_state, :atom, public?: true
            attribute :to_state, :atom, public?: true
            attribute :transition_name, :atom, public?: true
            attribute :triggered_by, :atom, public?: true
            attribute :occurred_at, :utc_datetime_usec, public?: true
          end

          relationships do
            belongs_to :workflow, MismatchedActorLogWorkflow, allow_nil?: false, public?: true
          end
        end

        defmodule MismatchedActorLogWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log MismatchedActorLog do
              belongs_to_actor :user, AshWorkflowTest.Reviewer
            end

            step :waiting do
              transition :resolve, to: :done
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/has no matching `belongs_to :user/
      )
    end
  end
end
