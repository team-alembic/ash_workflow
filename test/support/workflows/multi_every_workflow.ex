defmodule AshWorkflowTest.MultiEveryWorkflow do
  @moduledoc """
  Two `every` entities and a `transition_to` timeout sharing one step, to pin
  down what they do to each other.

  Each `every` measures its own `interval` against its own last-fired column;
  the timeout measures against `state_entered_at`, which neither `every`
  touches. See `AshWorkflow.Scheduler.EveryCollisionTest` for what that
  independence buys over sharing one anchor.

      waiting ──(escalation, 5 hours)──▶ escalated
              ├─ every 1 hour ──▶ send_reminder
              └─ every 2 hours ──▶ send_digest
  """

  use Ash.Resource,
    domain: AshWorkflowTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshWorkflow]

  workflow do
    scheduler AshWorkflow.Scheduler.Precise

    step :waiting do
      every :reminder, {1, :hours}, action: :send_reminder
      every :digest, {2, :hours}, action: :send_digest

      timeout :escalation, fire_after: {5, :hours}, transition_to: :escalated
    end

    step :escalated, terminal: true
  end

  code_interface do
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
    end

    update :send_reminder do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        AshWorkflowTest.MultiEveryWorkflow.bump(changeset, :reminder_count)
      end
    end

    update :send_digest do
      accept []
      require_atomic? false

      change fn changeset, _ctx ->
        AshWorkflowTest.MultiEveryWorkflow.bump(changeset, :digest_count)
      end
    end

    # `state_entered_at` is not writable, so it is forced in rather than
    # accepted. See `AshWorkflow.Transformers.AddAttributes`.
    update :set_clock do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :reminder_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :digest_count, :integer, allow_nil?: false, default: 0, public?: true
  end

  @doc false
  def bump(changeset, field) do
    Ash.Changeset.change_attribute(changeset, field, Ash.Changeset.get_data(changeset, field) + 1)
  end
end
