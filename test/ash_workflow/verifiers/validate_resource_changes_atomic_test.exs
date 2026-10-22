defmodule AshWorkflow.Verifiers.ValidateResourceChangesAtomicTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  defmodule NonAtomicChange do
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset
  end

  defmodule AtomicChange do
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(_changeset, _opts, _context), do: :ok
  end

  defp resource(blocks) do
    """
    defmodule ResourceChangesCase#{System.unique_integer([:positive])} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow, AshOban]

    #{blocks}

      attributes do
        uuid_v7_primary_key :id
      end
    end
    """
  end

  @timeout_workflow """
  workflow do
    step :review do
      timeout :expire, fire_after: {1, :days}, transition_to: :expired
    end

    step :expired, terminal: true
  end
  """

  describe "a non-atomic resource-level change with a timeout" do
    test "is rejected, naming the change and the timeout action" do
      code =
        resource("""
        #{@timeout_workflow}

        changes do
          change #{inspect(NonAtomicChange)}
        end
        """)

      assert_dsl_error(code, ~r/#{inspect(NonAtomicChange)} do not\s+implement `atomic\/3`/)
      assert_dsl_error(code, ~r/:__timeout_review_expire/)
    end

    test "is rejected for an anonymous function change" do
      assert_dsl_error(
        resource("""
        #{@timeout_workflow}

        changes do
          change fn changeset, _context -> changeset end
        end
        """),
        ~r/Ash.Resource.Change.Function do not\s+implement `atomic\/3`/
      )
    end
  end

  describe "an atomic resource-level change with a timeout" do
    test "compiles" do
      assert_dsl_compiles(
        resource("""
        #{@timeout_workflow}

        changes do
          change #{inspect(AtomicChange)}
        end
        """)
      )
    end
  end

  describe "a non-atomic resource-level change restricted to creates" do
    test "compiles" do
      assert_dsl_compiles(
        resource("""
        #{@timeout_workflow}

        changes do
          change #{inspect(NonAtomicChange)}, on: [:create]
        end
        """)
      )
    end
  end

  describe "a non-atomic resource-level change on a workflow with no timeouts" do
    test "compiles when every workflow action opts out of atomicity" do
      assert_dsl_compiles(
        resource("""
        workflow do
          step :checking do
            action :run_checks
            on_success :review
          end

          step :review do
            transition :approve, to: :approved
          end

          step :approved, terminal: true
        end

        actions do
          defaults [:read]

          update :run_checks do
            require_atomic? false
          end

          update :approve do
            require_atomic? false
          end
        end

        changes do
          change #{inspect(NonAtomicChange)}
        end
        """)
      )
    end

    test "is rejected when a transition action is built atomic" do
      assert_dsl_error(
        resource("""
        workflow do
          step :review do
            transition :approve, to: :approved
          end

          step :approved, terminal: true
        end

        actions do
          defaults [:read]

          update :approve
        end

        changes do
          change #{inspect(NonAtomicChange)}
        end
        """),
        ~r/:approve/
      )
    end
  end
end
