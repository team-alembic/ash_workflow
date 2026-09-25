defmodule BasicWorkflow.Subscription do
  @moduledoc """
  A subscription that falls into arrears and is chased for payment before it
  is cancelled.

  Flow: active → grace_period → suspended → cancelled

  Demonstrates:
  - A deadline measured from a date on the record: the grace period ends 14
    days after `invoice_due_at`, not 14 days after the step was entered
  - A recurring dunning email with `every`
  - A timeout that runs an action and stays in the step (the final notice)
  - A timeout that moves the record (giving up after 30 days)
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "subscriptions"
    repo(Example.Repo)
  end

  workflow do
    step :active do
      transition :payment_failed, to: :grace_period, accept: [:invoice_due_at]
    end

    step :grace_period do
      transition :payment_received, to: :active
      transition :cancel, to: :cancelled

      every :dunning_email do
        interval {3, :days}
        action :send_dunning_email
      end

      timeout :grace_expired do
        fire_after {14, :days}
        field :invoice_due_at
        transition_to :suspended
      end
    end

    step :suspended do
      transition :payment_received, to: :active
      transition :cancel, to: :cancelled

      timeout :final_notice, fire_after: {7, :days}, action: :send_final_notice
      timeout :give_up, fire_after: {30, :days}, transition_to: :cancelled
    end

    step :cancelled, terminal: true
  end

  code_interface do
    define :subscribe, action: :subscribe
  end

  actions do
    defaults [:read]

    create :subscribe do
      accept [:customer_email]
    end

    update :send_dunning_email do
      accept []
    end

    update :send_final_notice do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :customer_email, :string, allow_nil?: false
    attribute :invoice_due_at, :utc_datetime_usec
  end
end
