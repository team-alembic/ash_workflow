defmodule AshWorkflow.Verifiers.ValidateFireAtTest do
  @moduledoc """
  The compile-time rules `fire_at` brings: exactly one of `fire_after` and
  `fire_at`, and no `field` alongside `fire_at`.
  """
  use ExUnit.Case

  import AshWorkflowTest.DslAssertions

  defp workflow(module, timeout) do
    """
    defmodule #{module} do
      use Ash.Resource,
        domain: AshWorkflowTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshWorkflow, AshOban]

      workflow do
        step :waiting do
          transition :resolve, to: :done

          #{timeout}
        end

        step :done, terminal: true
        step :escalated, terminal: true
      end

      actions do
        defaults [:read]

        update :ping do
          accept []
        end
      end

      attributes do
        uuid_v7_primary_key :id
        attribute :title, :string, allow_nil?: false, public?: true
        attribute :next_check_at, :utc_datetime_usec, public?: true
      end
    end
    """
  end

  test "rejects a timeout declaring both fire_after and fire_at" do
    assert_dsl_error(
      workflow(
        "BothDurationsWorkflow",
        "timeout :both, fire_after: {3, :days}, fire_at: :next_check_at, transition_to: :escalated"
      ),
      ~r/must have either fire_after or fire_at, not both/
    )
  end

  test "rejects a timeout declaring neither fire_after nor fire_at" do
    assert_dsl_error(
      workflow("NoDurationWorkflow", "timeout :neither, transition_to: :escalated"),
      ~r/must have either fire_after or fire_at/
    )
  end

  test "rejects fire_at combined with field" do
    assert_dsl_error(
      workflow(
        "FireAtWithFieldWorkflow",
        "timeout :both_fields, fire_at: :next_check_at, field: :next_check_at, transition_to: :escalated"
      ),
      ~r/has both fire_at and field/
    )
  end

  test "rejects a fire_at field that does not exist" do
    assert_dsl_error(
      workflow(
        "MissingFireAtWorkflow",
        "timeout :missing, fire_at: :nonexistent_field, transition_to: :escalated"
      ),
      ~r/references field :nonexistent_field/
    )
  end

  test "rejects a fire_at field that is not a datetime" do
    assert_dsl_error(
      workflow(
        "NonDatetimeFireAtWorkflow",
        "timeout :wrong_type, fire_at: :title, transition_to: :escalated"
      ),
      ~r/must be a datetime type/
    )
  end

  test "rejects repeat: true with fire_at" do
    assert_dsl_error(
      workflow(
        "RepeatFireAtWorkflow",
        "timeout :repeating, fire_at: :next_check_at, action: :ping, repeat: true"
      ),
      ~r/repeat: true with field: :next_check_at/
    )
  end

  test "does not apply the precision floor to a fire_at timeout" do
    # `AshWorkflow.Verifiers.ValidateTimeoutPrecision` compares `fire_after`
    # against the scheduler's floor. A `fire_at` timeout has no duration to
    # compare, and the default Oban scheduler's one-minute floor does not
    # reject it.
    assert_dsl_compiles(
      workflow(
        "SubMinuteFireAtWorkflow",
        "timeout :instant, fire_at: :next_check_at, transition_to: :escalated"
      )
    )
  end
end
