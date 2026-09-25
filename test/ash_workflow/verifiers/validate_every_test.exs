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

  describe "wall-clock schedule validation" do
    defp wall_clock_workflow(module, every_body, extra_attributes \\ "") do
      """
      defmodule #{module} do
        use Ash.Resource,
          domain: AshWorkflowTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshWorkflow, AshOban]

        workflow do
          step :waiting do
            transition :resolve, to: :done

            every :digest do
      #{every_body}
              action :send_digest
            end
          end

          step :done, terminal: true
        end

        actions do
          update :send_digest do
            accept []
          end
        end

        attributes do
          uuid_v7_primary_key :id
          attribute :title, :string, allow_nil?: false, public?: true
      #{extra_attributes}
        end
      end
      """
    end

    test "rejects an every declaring neither interval nor at" do
      assert_dsl_error(
        wall_clock_workflow("NoScheduleWorkflow", ""),
        ~r/declares neither interval nor at/
      )
    end

    test "accepts an interval in days alongside at, as a stride between fires" do
      every =
        AshWorkflowTest.StrideWorkflow
        |> AshWorkflow.Info.workflow_graph()
        |> Map.fetch!(:waiting)
        |> Map.fetch!(:everys)
        |> Enum.find(&(&1.name == :digest))

      assert every.interval == {14, :days}
      assert every.at == ~T[09:00:00]
      assert every.on == [:mon]
    end

    test "rejects an interval alongside at given in anything but days" do
      assert_dsl_error(
        wall_clock_workflow("SubDayStrideWorkflow", """
                  interval {36, :hours}
                  at ~T[09:00:00]
                  time_zone "Australia/Sydney"
        """),
        ~r/counts local days between fires, so it must be given in :days/
      )
    end

    test "rejects at without a time_zone, since a wall-clock time is not an instant" do
      assert_dsl_error(
        wall_clock_workflow("NoTimeZoneWorkflow", """
                  at ~T[09:00:00]
        """),
        ~r/declares at: ~T\[09:00:00\] without a time_zone/
      )
    end

    test "rejects on without an at to fire" do
      assert_dsl_error(
        wall_clock_workflow("DaysWithoutAtWorkflow", """
                  interval {1, :days}
                  on [:mon]
        """),
        ~r/declares on: \[:mon\] without an at to fire/
      )
    end

    test "rejects time_zone without an at to place in that zone" do
      assert_dsl_error(
        wall_clock_workflow("TimeZoneWithoutAtWorkflow", """
                  interval {1, :days}
                  time_zone "Australia/Sydney"
        """),
        ~r/declares time_zone: "Australia\/Sydney" without an at to place in that zone/
      )
    end

    test "rejects a literal zone the time zone database does not know" do
      assert_dsl_error(
        wall_clock_workflow("UnknownZoneWorkflow", """
                  at ~T[09:00:00]
                  time_zone "Mars/Olympus_Mons"
        """),
        ~r/declares time_zone: "Mars\/Olympus_Mons", which the configured time zone database rejected/
      )
    end

    test "rejects a time_zone attribute that does not exist" do
      assert_dsl_error(
        wall_clock_workflow("MissingZoneAttributeWorkflow", """
                  at ~T[09:00:00]
                  time_zone :candidate_time_zone
        """),
        ~r/declares time_zone: :candidate_time_zone, but no attribute or calculation with that name exists/
      )
    end

    test "rejects a time_zone attribute that is not a string" do
      assert_dsl_error(
        wall_clock_workflow(
          "NonStringZoneAttributeWorkflow",
          """
                    at ~T[09:00:00]
                    time_zone :candidate_time_zone
          """,
          "    attribute :candidate_time_zone, :integer, public?: true"
        ),
        ~r/declares time_zone: :candidate_time_zone, which has type/
      )
    end

    test "accepts a time_zone naming an expression calculation that reaches a related record" do
      every =
        AshWorkflowTest.RelatedZoneWorkflow
        |> AshWorkflow.Info.workflow_graph()
        |> Map.fetch!(:waiting)
        |> Map.fetch!(:everys)
        |> Enum.find(&(&1.name == :digest))

      assert every.time_zone == :candidate_time_zone

      assert Ash.Resource.Info.attribute(
               AshWorkflowTest.RelatedZoneWorkflow,
               :candidate_time_zone
             ) == nil

      assert Ash.Resource.Info.calculation(
               AshWorkflowTest.RelatedZoneWorkflow,
               :candidate_time_zone
             )
    end

    test "rejects a time_zone naming a module calculation, which no filter can evaluate" do
      assert_dsl_error(
        """
        defmodule ModuleCalcZoneWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          defmodule ZoneCalculation do
            use Ash.Resource.Calculation

            @impl true
            def calculate(records, _opts, _context), do: Enum.map(records, fn _ -> "Etc/UTC" end)
          end

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :digest do
                at ~T[09:00:00]
                time_zone :computed_zone
                action :send_digest
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_digest do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end

          calculations do
            calculate :computed_zone, :string, ZoneCalculation
          end
        end
        """,
        ~r/which is a module calculation and so cannot be evaluated by the data layer/
      )
    end

    test "rejects a time_zone calculation that is not a string" do
      assert_dsl_error(
        """
        defmodule NonStringCalcZoneWorkflow do
          use Ash.Resource,
            domain: AshWorkflowTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshWorkflow, AshOban]

          workflow do
            step :waiting do
              transition :resolve, to: :done

              every :digest do
                at ~T[09:00:00]
                time_zone :computed_zone
                action :send_digest
              end
            end

            step :done, terminal: true
          end

          actions do
            update :send_digest do
              accept []
            end
          end

          attributes do
            uuid_v7_primary_key :id
            attribute :title, :string, allow_nil?: false, public?: true
          end

          calculations do
            calculate :computed_zone, :integer, expr(1)
          end
        end
        """,
        ~r/declares time_zone: :computed_zone, which has type/
      )
    end

    test "rejects a day name that is not a day" do
      assert_dsl_error(
        wall_clock_workflow("BadDayWorkflow", """
                  at ~T[09:00:00]
                  on [:mon, :caturday]
                  time_zone "Australia/Sydney"
        """),
        ~r/Expected day names from/
      )
    end

    test "accepts a wall-clock every, and exposes it on workflow_graph" do
      every =
        AshWorkflowTest.WallClockWorkflow
        |> AshWorkflow.Info.workflow_graph()
        |> Map.fetch!(:waiting)
        |> Map.fetch!(:everys)
        |> Enum.find(&(&1.name == :digest))

      assert every.interval == nil
      assert every.at == ~T[09:00:00]
      assert every.on == [:mon, :tue, :wed, :thu, :fri]
      assert every.time_zone == :candidate_time_zone
    end

    test "an at every is exempt from the scheduler precision floor" do
      # A daily occurrence clears every scheduler's floor, so
      # `AshWorkflow.Verifiers.ValidateTimeoutPrecision` has nothing to check.
      # A one-second `interval` on the same Oban scheduler would be rejected.
      assert Code.ensure_compiled(AshWorkflowTest.WallClockWorkflow) ==
               {:module, AshWorkflowTest.WallClockWorkflow}
    end
  end
end
