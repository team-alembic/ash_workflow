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

  describe "last_fired_field validation" do
    test "rejects last_fired_field: :state_entered_at" do
      assert_dsl_error(
        """
        defmodule StateEnteredAtLastFiredFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {1, :hours}
                action :send_reminder
                last_fired_field :state_entered_at
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
        ~r/has last_fired_field: :state_entered_at.*reintroducing the starvation/s
      )
    end

    test "rejects last_fired_field equal to the workflow's own state attribute" do
      assert_dsl_error(
        """
        defmodule StateAttributeLastFiredFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {1, :hours}
                action :send_reminder
                last_fired_field :state
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
        ~r/has last_fired_field: :state, which is the workflow's own state attribute/
      )
    end

    test "rejects last_fired_field naming an existing attribute of the wrong type" do
      assert_dsl_error(
        """
        defmodule WrongTypeLastFiredFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {1, :hours}
                action :send_reminder
                last_fired_field :title
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
        ~r/which references an existing attribute of type Ash\.Type\.String.*must be a datetime type/s
      )
    end

    test "rejects two everys sharing the same last_fired_field" do
      assert_dsl_error(
        """
        defmodule SharedLastFiredFieldWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :reminder do
                interval {1, :hours}
                action :send_reminder
                last_fired_field :shared_last_fired_at
              end

              every :digest do
                interval {2, :hours}
                action :send_digest
                last_fired_field :shared_last_fired_at
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_reminder do
              accept []
            end

            update :send_digest do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end
        end
        """,
        ~r/last_fired_field :shared_last_fired_at is shared by more than one every/
      )
    end
  end
end
