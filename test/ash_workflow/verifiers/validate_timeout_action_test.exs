defmodule AshWorkflow.Verifiers.ValidateTimeoutActionTest do
  @moduledoc """
  A timeout naming an action the resource does not define is a compile error,
  whichever scheduler runs it.
  """
  use ExUnit.Case, async: true

  import AshWorkflowTest.DslAssertions

  describe "a timeout naming an action that does not exist" do
    # Under the default scheduler AshOban's own verifier rejects this first,
    # on the trigger it generated. A workflow scheduled by something other
    # than Oban has no trigger, so nothing checked it before this.
    test "is rejected under a scheduler that generates no Oban trigger" do
      assert_dsl_error(
        """
        defmodule MissingTimeoutActionWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow]

          workflow do
            scheduler AshWorkflow.Scheduler.Precise

            step :waiting do
              transition :resolve, to: :done
              timeout :reminder, after: {3, :days}, action: :send_reminder
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/Timeout :reminder on step :waiting references action :send_reminder, but no such action is defined/
      )
    end

    test "is rejected under the default scheduler too" do
      assert_dsl_error(
        """
        defmodule MissingObanTimeoutActionWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done
              timeout :reminder, after: {3, :days}, action: :send_reminder
            end

            step :done, terminal: true
          end

          attributes do
            uuid_v7_primary_key :id
          end
        end
        """,
        ~r/No such action :send_reminder|references action :send_reminder/
      )
    end
  end
end
