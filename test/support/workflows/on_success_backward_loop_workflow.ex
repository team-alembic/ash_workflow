defmodule AshWorkflowTest.OnSuccessBackwardLoopWorkflow do
  @moduledoc """
  Conditional `on_success` routing backward to an earlier step — a two-step
  retry loop, as opposed to `OnSuccessSelfLoopWorkflow`'s single-step version.
  `:collecting`'s only route points back to `:validating`, which is earlier in
  declaration order and already visited by the time reachability's BFS gets
  there; the visited-set check is what keeps that from being treated as
  unreachable or looping forever at compile time.

  start → validating ──(valid)─────────────▶ submitted
                      └─(invalid)──────────▶ collecting ──▶ validating (loop back)
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :validating do
      action :run_validation

      on_success :submitted, when: expr(valid == true)
      on_success :collecting, when: expr(valid == false)
      on_error :validation_failed
    end

    step :collecting do
      action :run_collection
      on_success :validating
    end

    step :submitted, terminal: true
    step :validation_failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept []
    end

    update :run_validation do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :valid,
          Ash.Changeset.get_data(changeset, :info_count) >= 2
        )
      end
    end

    update :run_collection do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :info_count,
          Ash.Changeset.get_data(changeset, :info_count) + 1
        )
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :info_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :valid, :boolean, public?: true
  end
end
