defmodule DocumentApproval.Document do
  @moduledoc """
  A document that must be signed off by **two different administrators** before
  it is published.

      drafting ──(submit)──▶ validating ──▶ in_review ──(approve)──▶ in_review
                                  │             │        (first approval)
                                  │             │
                                  │             ╰─(approve)──▶ approved
                                  │             │        (second approval)
                                  │             ╰─(reject)────▶ rejected
                                  ╰──on_error──▶ validation_failed

  The interesting part is that `:approve` is a *single* action that does not
  always advance the workflow. Its target is chosen at runtime by conditional
  routes: if nobody has approved yet it routes back to `:in_review`, and only
  the second, different approver routes to `:approved`.

  Route conditions are evaluated against the record as it was *before* the
  update, which is what makes this work — the first approver sees
  `first_approver_id` as nil, and the second sees it set.
  """

  use Ash.Resource,
    domain: DocumentApproval.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow]

  postgres do
    table "documents"
    repo DocumentApproval.Repo
  end

  workflow do
    # Sign-off is measured in hours, not seconds, so there is no reason to poll
    # every minute. See the timeouts guide for what polling costs.
    check_interval "*/5 * * * *"

    step :validating do
      action :validate
      on_success :in_review
      on_error :validation_failed
    end

    step :in_review do
      policy actor_attribute_equals(:role, :admin)

      # One action, two possible destinations. The first approval loops back
      # here; the second completes the document.
      transition :approve do
        route :approved, when: expr(not is_nil(first_approver_id))
        route :in_review, when: expr(is_nil(first_approver_id))
      end

      transition :reject, to: :rejected, accept: [:rejection_reason]

      timeout :nudge, after: {2, :days}, action: :send_review_nudge, repeat: true
      timeout :expire, after: {14, :days}, transition_to: :expired
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :expired, terminal: true
    step :validation_failed, terminal: true
  end

  code_interface do
    define :submit, action: :submit
    define :read_all, action: :read
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title, :body, :author_email]
    end

    update :validate do
      accept []
      require_atomic? false

      change DocumentApproval.Document.Validate
    end

    update :send_review_nudge do
      accept []
      require_atomic? false

      change DocumentApproval.Document.SendNudge
    end

    # Declaring the transition action ourselves lets us attach business logic to
    # it; AshWorkflow merges its own state transition into the action rather
    # than generating a second one.
    update :approve do
      accept []
      require_atomic? false

      change DocumentApproval.Document.RecordApproval
    end
  end

  policies do
    policy action(:submit) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :author_email, :string, allow_nil?: false, public?: true

    attribute :first_approver_id, :uuid, public?: true
    attribute :second_approver_id, :uuid, public?: true
    attribute :rejection_reason, :string, public?: true
    attribute :nudges_sent, :integer, allow_nil?: false, default: 0, public?: true

    create_timestamp :inserted_at
  end
end
