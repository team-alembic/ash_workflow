defmodule AshWorkflowDemo.ATS.Candidate do
  @moduledoc """
  The only resource in the demo. Represents a conference attendee who
  submitted themselves as a candidate for the single open role.
  """

  use Ash.Resource,
    domain: AshWorkflowDemo.ATS,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow],
    notifiers: [AshWorkflowDemo.ATS.Candidate.Notifier]

  postgres do
    table "candidates"
    repo AshWorkflowDemo.Repo
  end

  workflow do
    step :verifying do
      action :run_verification
      on_success :review
      on_error :verification_failed
    end

    step :review do
      transition :hire, to: :hired
      transition :reject, to: :rejected
      transition :position_filled, to: :position_filled

      timeout :auto_reject, after: {30, :seconds}, transition_to: :auto_rejected
    end

    step :hired, terminal: true
    step :rejected, terminal: true
    step :auto_rejected, terminal: true
    step :position_filled, terminal: true
    step :verification_failed, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :pitch, :string, allow_nil?: false, public?: true
    attribute :avatar_url, :string, allow_nil?: false, public?: true
    attribute :score, :integer, public?: true
    attribute :score_reason, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    create :start do
      accept [:name, :pitch, :avatar_url]
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
end
