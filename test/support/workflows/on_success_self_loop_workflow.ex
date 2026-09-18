defmodule AshWorkflowTest.OnSuccessSelfLoopWorkflow do
  @moduledoc """
  A conditional `on_success` route whose target is its own step — a retry
  loop entirely within one automatic step, the way `order_fulfilment`'s
  `on_error` loops backward. Deliberately supported: reachability only asks
  whether a step is reachable from the initial step, not whether the path to
  it is acyclic, and a route targeting its own step is already reachable
  (it is the step doing the routing). Nothing about a self-loop is rejected
  at compile time.

  start → attempting ──(attempts < 3)──▶ attempting  (retry, stays put)
                      └─(attempts >= 3)─▶ succeeded
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow, AshOban]

  workflow do
    step :attempting do
      action :run_attempt

      on_success :attempting, when: expr(attempts < 3)
      on_success :succeeded, when: expr(attempts >= 3)
      on_error :attempting_failed
    end

    step :succeeded, terminal: true
    step :attempting_failed, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    create :create do
      accept []
    end

    update :run_attempt do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        Ash.Changeset.change_attribute(
          changeset,
          :attempts,
          Ash.Changeset.get_data(changeset, :attempts) + 1
        )
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
  end
end
