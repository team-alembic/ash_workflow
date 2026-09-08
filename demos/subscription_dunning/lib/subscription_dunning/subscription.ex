defmodule SubscriptionDunning.Subscription do
  @moduledoc """
  A subscription that falls into arrears and is chased for payment — the
  "dunning" process — before eventually being cancelled.

      active ──(payment_failed)──▶ grace_period ──(payment_received)──▶ active
                                        │                                 ▲
                                        │  every 3 days: dunning email    │
                                        │                                 │
                                        ╰─ grace ends ──▶ suspended ──────╯
                                                              │  (payment_received)
                                                              ╰─ 30 days ──▶ cancelled

  This is the demo for **timeouts**, and specifically for the two kinds of
  deadline that look similar and behave differently:

  - `:dunning_email` uses `repeat: true`. It fires every three days for as long
    as the subscription stays in `:grace_period`, resetting the clock each time.
  - `:grace_expired` uses `field: :grace_period_ends_at`. Its deadline is a
    date stored on the record — set by the billing system, and different per
    customer — rather than "N days since entering this state".

  Those two cannot be combined, and the library rejects it at compile time:
  a repeating timeout works by resetting its field to now, and resetting
  `grace_period_ends_at` would claim the grace period restarted when it did not.
  """

  use Ash.Resource,
    domain: SubscriptionDunning.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "subscriptions"
    repo SubscriptionDunning.Repo
  end

  workflow do
    # Dunning is measured in days. Polling every minute would be 1,440 queries a
    # day per trigger to notice a deadline that moves once a day.
    check_interval "0 * * * *"

    step :active do
      transition :payment_failed, to: :grace_period, accept: [:grace_period_ends_at]
    end

    step :grace_period do
      transition :payment_received, to: :active
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]

      # Fires repeatedly while the customer remains in arrears.
      timeout :dunning_email, after: {3, :days}, action: :send_dunning_email, repeat: true

      # Fires once, against a date the billing system put on the record. The
      # duration is relative to that field, so {1, :minutes} means "as soon as
      # grace_period_ends_at has passed" — durations must be positive, and must
      # be at least a minute because cron cannot poll faster than that. With an
      # hourly check_interval the exact duration makes no observable difference.
      timeout :grace_expired,
        after: {1, :minutes},
        field: :grace_period_ends_at,
        transition_to: :suspended
    end

    step :suspended do
      transition :payment_received, to: :active
      transition :cancel, to: :cancelled, accept: [:cancellation_reason]

      timeout :final_notice, after: {7, :days}, action: :send_final_notice
      timeout :give_up, after: {30, :days}, transition_to: :cancelled
    end

    step :cancelled, terminal: true
  end

  code_interface do
    define :subscribe, action: :subscribe
  end

  actions do
    defaults [:read]

    create :subscribe do
      accept [:customer_email, :plan, :monthly_cents]
    end

    update :send_dunning_email do
      accept []
      require_atomic? false
      change SubscriptionDunning.Subscription.SendDunningEmail
    end

    update :send_final_notice do
      accept []
      require_atomic? false
      change SubscriptionDunning.Subscription.SendFinalNotice
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :customer_email, :string, allow_nil?: false, public?: true
    attribute :plan, :string, allow_nil?: false, public?: true
    attribute :monthly_cents, :integer, allow_nil?: false, public?: true

    # The deadline the :grace_expired timeout measures against. Set by whatever
    # marks the payment as failed, so each customer can get a different one.
    attribute :grace_period_ends_at, :utc_datetime_usec, public?: true

    attribute :dunning_emails_sent, :integer, allow_nil?: false, default: 0, public?: true
    attribute :final_notice_sent?, :boolean, allow_nil?: false, default: false, public?: true
    attribute :cancellation_reason, :string, public?: true
  end
end
