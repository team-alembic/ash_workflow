defmodule AshWorkflow.Verifiers.ValidateUndoTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  defp workflow(workflow_block) do
    """
    defmodule UndoCase#{System.unique_integer([:positive])} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow]

      workflow do
    #{workflow_block}
      end

      attributes do
        uuid_v7_primary_key :id
      end
    end
    """
  end

  describe "undo without a transition log" do
    test "is rejected" do
      assert_dsl_error(
        workflow("""
            undo do
              within {30, :minutes}
            end

            step :review do
              transition :approve, to: :done, undoable?: true
            end

            step :done, terminal: true
        """),
        ~r/`undo` requires a `transition_log`/
      )
    end
  end

  describe "a log with no `undoes` relationship" do
    test "is rejected" do
      assert_dsl_error(
        """
        defmodule NoUndoesLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :from_state, :atom, public?: true
            attribute :to_state, :atom, allow_nil?: false, public?: true
            attribute :transition_name, :atom, allow_nil?: false, public?: true
            attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
            attribute :triggered_by, :atom, allow_nil?: false, public?: true
          end

          relationships do
            belongs_to :workflow, NoUndoesWorkflow, allow_nil?: false
          end
        end

        defmodule NoUndoesWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log NoUndoesLog

            undo do
            end

            step :review do
              transition :approve, to: :done, undoable?: true
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/no self-referencing `undoes` relationship/
      )
    end
  end

  describe "an undo block with nothing undoable" do
    test "is rejected" do
      assert_dsl_error(
        workflow("""
            transition_log AshWorkflowTest.UndoLog

            undo do
            end

            step :review do
              transition :approve, to: :done
            end

            step :done, terminal: true
        """),
        ~r/no transition is marked `undoable\?: true`/
      )
    end
  end

  describe "an undoable transition with no undo block" do
    test "is rejected" do
      assert_dsl_error(
        workflow("""
            step :review do
              transition :approve, to: :done, undoable?: true
            end

            step :done, terminal: true
        """),
        ~r/marked `undoable\?: true`, but this workflow has no `undo` block/
      )
    end
  end

  describe "same_actor? without a recorded actor" do
    test "is rejected" do
      assert_dsl_error(
        """
        defmodule ActorlessLog do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets

          actions do
            defaults [:read, :create]
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :from_state, :atom, public?: true
            attribute :to_state, :atom, allow_nil?: false, public?: true
            attribute :transition_name, :atom, allow_nil?: false, public?: true
            attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
            attribute :triggered_by, :atom, allow_nil?: false, public?: true
          end

          relationships do
            belongs_to :workflow, ActorlessWorkflow, allow_nil?: false
            belongs_to :undoes, __MODULE__, allow_nil?: true
          end
        end

        defmodule ActorlessWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            transition_log ActorlessLog

            undo do
              same_actor? true
            end

            step :review do
              transition :approve, to: :done, undoable?: true
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/`same_actor\?` is set, but transition_log .* records no actor/
      )
    end
  end
end
