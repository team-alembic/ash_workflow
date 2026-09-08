defmodule AshWorkflowDemo.ATS.Candidate do
  @moduledoc """
  The only resource in the demo. Represents a conference attendee who
  submitted themselves as a candidate for the single open role.
  """

  use Ash.Resource,
    domain: AshWorkflowDemo.ATS,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban],
    notifiers: [AshWorkflowDemo.ATS.Candidate.Notifier]

  postgres do
    table "candidates"
    repo AshWorkflowDemo.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :pitch, :string, allow_nil?: false, public?: true
    attribute :avatar_url, :string, allow_nil?: false, public?: true
    attribute :score, :integer, public?: true
    attribute :score_reason, :string, public?: true

    # When the scorer is allowed to pick this candidate up. Set a few seconds
    # into the future on :start so the audience sees the :submitted step on the
    # projector, rather than the scorer blocking a connection to create suspense.
    attribute :verify_after, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    create :start do
      accept [:name, :pitch, :avatar_url]
      change AshWorkflowDemo.ATS.Candidate.SetVerifyAfter
    end

    update :run_verification do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.FakeScore
    end

    update :hire do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.Cascade
    end
  end

  workflow do
    # The dwell the audience sees. :verify_after is a per-candidate timestamp,
    # so the delay is data on the record rather than a sleep inside the scorer.
    step :submitted do
      timeout :begin_verification,
        after: {1, :seconds},
        field: :verify_after,
        transition_to: :verifying,
        # AshWorkflowDemo.DemoScheduler invokes this trigger every second,
        # which is what makes a sub-minute deadline honourable here. Cron alone
        # could not, so without this the duration is a compile error.
        self_scheduled?: true
    end

    step :verifying do
      action :run_verification
      on_success :review
      on_error :verification_failed
    end

    step :review do
      transition :hire, to: :hired
      transition :reject, to: :rejected
      transition :position_filled, to: :position_filled

      # Also driven by DemoScheduler — a 30-second deadline is exactly what cron
      # cannot express, which is why the demo schedules it itself.
      timeout :auto_reject,
        after: {30, :seconds},
        transition_to: :auto_rejected,
        self_scheduled?: true
    end

    step :hired, terminal: true
    step :rejected, terminal: true
    step :auto_rejected, terminal: true
    step :position_filled, terminal: true
    step :verification_failed, terminal: true
  end
end
