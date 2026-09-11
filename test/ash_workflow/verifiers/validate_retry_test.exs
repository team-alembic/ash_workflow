defmodule AshWorkflow.Verifiers.ValidateRetryTest do
  @moduledoc """
  A `retry` block only means something on a step whose action the scheduler
  actually runs. A manual step, a wait state, and a terminal step have no
  generated trigger to retry, so `AshWorkflow.Verifiers.ValidateRetry` rejects
  a `retry` block declared on one of them rather than letting it compile and
  do nothing.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  defp workflow(name, step_body) do
    """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow, AshOban]

      workflow do
        #{step_body}

        step :done, terminal: true
      end

      actions do
        update :process do
          accept []
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :title, :string, allow_nil?: false, public?: true
      end
    end
    """
  end

  describe "rejects a retry block on a step nothing is scheduled for" do
    test "a manual step" do
      assert_dsl_error(
        workflow(
          "RetryOnManualStep",
          """
          step :review do
            transition :approve, to: :done

            retry do
              max_attempts 2
            end
          end
          """
        ),
        ~r/Step :review declares a retry block, but it is a manual step or a wait state/
      )
    end

    test "a wait state" do
      assert_dsl_error(
        workflow(
          "RetryOnWaitState",
          """
          step :queued do
            timeout :release, fire_after: {1, :minutes}, transition_to: :done

            retry do
              max_attempts 2
            end
          end
          """
        ),
        ~r/Step :queued declares a retry block, but it is a manual step or a wait state/
      )
    end

    test "a terminal step" do
      assert_dsl_error(
        workflow(
          "RetryOnTerminalStep",
          """
          step :review do
            transition :approve, to: :finished
          end

          step :finished do
            terminal true

            retry do
              max_attempts 2
            end
          end
          """
        ),
        ~r/Step :finished declares a retry block, but it is terminal/
      )
    end
  end

  describe "rejects a bare integer backoff" do
    test "backoff takes a duration tuple, not a bare integer" do
      assert_dsl_error(
        workflow(
          "RetryBackoffBareInteger",
          """
          step :processing do
            action :process
            on_success :done
            on_error :done

            retry do
              max_attempts 2
              backoff 10
            end
          end
          """
        ),
        ~r/backoff/
      )
    end
  end

  describe "accepts a retry block where there is work to retry" do
    test "an automatic step" do
      code =
        workflow(
          "RetryOnAutomaticStep",
          """
          step :processing do
            action :process
            on_success :done
            on_error :done

            retry do
              max_attempts 2
            end
          end
          """
        )

      Code.compile_string(code)

      assert Code.ensure_loaded?(RetryOnAutomaticStep)
    end
  end
end
