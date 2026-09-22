defmodule AshWorkflow.Verifiers.ValidateEveryTest do
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  describe "until validation" do
    test "accepts an every with a bound, and exposes it on workflow_graph" do
      assert AshWorkflowTest.EveryUntilWorkflow.__info__(:module) ==
               AshWorkflowTest.EveryUntilWorkflow

      every =
        AshWorkflowTest.EveryUntilWorkflow
        |> AshWorkflow.Info.workflow_graph()
        |> Map.fetch!(:waiting)
        |> Map.fetch!(:everys)
        |> Enum.find(&(&1.name == :reminder))

      assert every.interval == {1, :hours}
      assert every.until == {3, :hours}
    end

    test "rejects an until shorter than interval" do
      assert_dsl_error(
        """
        defmodule TooShortEveryUntilWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {3, :days}
                action :send_reminder
                until {1, :days}
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_reminder do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/until: \{1, :days\}, which is not longer than interval/
      )
    end

    test "rejects an until equal to interval, since that leaves no room to fire even once" do
      assert_dsl_error(
        """
        defmodule EqualEveryUntilWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {3, :days}
                action :send_reminder
                until {3, :days}
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_reminder do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/until: \{3, :days\}, which is not longer than interval/
      )
    end
  end
end
