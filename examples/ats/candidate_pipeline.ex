defmodule ATS.CandidatePipeline do
  @moduledoc """
  A full applicant tracking system modeled as a single Ash resource with AshWorkflow.

  This shows how a real hiring pipeline — spanning days or weeks, involving multiple
  people in different roles — can be expressed declaratively. Every state, transition,
  timeout, and authorization rule lives in one place.

  ## The pipeline

      (record created)
        │
        ▼
      process_application  (automatic — parse resume, check for duplicates)
        │
        ├─ on_success ──▶  recruiter_screen
        └─ on_error ────▶  application_failed
        │
        ▼
      recruiter_screen  (manual — recruiter reviews application)
        │
        ├─ advance ──────────▶  phone_screen
        ├─ reject_application ▶  rejected
        ├─ hold ─────────────▶  on_hold
        │
        │  timeout: 2 days → send reminder to recruiter
        │  timeout: 7 days → auto-escalate
        │
        ▼
      phone_screen  (automatic — send scheduling link via Calendly)
        │
        ├─ on_success ──▶  awaiting_phone_result
        └─ on_error ────▶  scheduling_failed
        │
        ▼
      awaiting_phone_result  (manual — recruiter logs outcome)
        │
        ├─ pass ────────▶  onsite_interview
        ├─ fail ────────▶  rejected
        ├─ reschedule ──▶  phone_screen
        │
        │  timeout: 5 days → nudge interviewer
        │
        ▼
      onsite_interview  (automatic — send onsite scheduling email)
        │
        ├─ on_success ──▶  awaiting_panel_decision
        │
        ▼
      awaiting_panel_decision  (manual — hiring manager decides)
        │
        ├─ offer ────────────▶  generate_offer
        ├─ reject_candidate ─▶  rejected
        │
        ▼
      generate_offer  (automatic — create offer letter, send to candidate)
        │
        ├─ on_success ──▶  awaiting_offer_response
        └─ on_error ────▶  offer_generation_failed
        │
        ▼
      awaiting_offer_response  (manual — candidate responds)
        │
        ├─ accept ──────▶  hired
        ├─ decline ─────▶  offer_declined
        ├─ negotiate ───▶  generate_offer
        │
        │  timeout: 3 days → follow-up email (repeating)
        │  timeout: 14 days → offer expires
        │
        ▼
      hired  (terminal)

  ## Roles

  - **Recruiter** — screens applications, logs phone screen results, manages pipeline
  - **Hiring manager** — makes final interview decisions, approves offers
  - **Candidate** — responds to offers (via external action or webhook)

  ## Usage

      # A new application comes in. Creating the record puts the workflow
      # into its initial step (:process_application).
      {:ok, pipeline} = CandidatePipeline.apply(%{
        candidate_name: "Jane Smith",
        candidate_email: "jane@example.com",
        position: "Senior Engineer",
        resume_url: "https://example.com/resume.pdf"
      })

      # process_application runs automatically via Oban.
      # If successful, the workflow moves to :recruiter_screen.

      # Recruiter reviews and advances the candidate
      CandidatePipeline.advance(pipeline, actor: recruiter)

      # phone_screen runs automatically — sends scheduling link.
      # Recruiter logs the result after the call happens.
      CandidatePipeline.pass(pipeline, %{notes: "Strong communicator"}, actor: recruiter)

      # onsite_interview runs automatically — sends scheduling email.
      # Hiring manager makes the call after the panel meets.
      CandidatePipeline.offer(pipeline, %{salary: 150_000, equity: "0.1%"}, actor: hiring_manager)

      # generate_offer runs automatically — creates and sends the offer letter.
      # Candidate accepts (could come from a webhook or manual entry).
      CandidatePipeline.accept(pipeline, actor: candidate)
      # => state is now :hired
  """

  use Ash.Resource,
    domain: ATS.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "candidate_pipelines"
    repo(Example.Repo)
  end

  workflow do
    # ── Automatic: parse resume, check for duplicate applications ──
    step :process_application do
      action :process_application
      on_success :recruiter_screen
      on_error :application_failed
    end

    # ── Manual: recruiter reviews the application ──
    step :recruiter_screen do
      policy actor_attribute_equals(:role, :recruiter)

      transition :advance, to: :phone_screen
      transition :reject_application, to: :rejected
      transition :hold, to: :on_hold

      timeout :reminder, fire_after: {2, :days}, action: :send_recruiter_reminder
      timeout :escalation, fire_after: {7, :days}, transition_to: :escalated
    end

    # ── Manual: on_hold — recruiter can revisit later ──
    step :on_hold do
      policy actor_attribute_equals(:role, :recruiter)

      transition :reactivate, to: :recruiter_screen
      transition :reject_held, to: :rejected

      timeout :stale_check, fire_after: {30, :days}, action: :notify_stale_candidate
    end

    # ── Automatic: send scheduling link for phone screen ──
    step :phone_screen do
      action :schedule_phone_screen
      on_success :awaiting_phone_result
      on_error :scheduling_failed
    end

    # ── Manual: recruiter logs the phone screen outcome ──
    step :awaiting_phone_result do
      policy actor_attribute_equals(:role, :recruiter)

      transition :pass, to: :onsite_interview
      transition :fail, to: :rejected
      transition :reschedule, to: :phone_screen

      timeout :nudge, fire_after: {5, :days}, action: :remind_phone_screen_result
    end

    # ── Automatic: send onsite interview scheduling email ──
    step :onsite_interview do
      action :schedule_onsite
      on_success :awaiting_panel_decision
    end

    # ── Manual: hiring manager decides after the panel ──
    step :awaiting_panel_decision do
      policy actor_attribute_equals(:role, :hiring_manager)

      transition :offer, to: :generate_offer
      transition :reject_candidate, to: :rejected
    end

    # ── Automatic: create offer letter, send to candidate ──
    step :generate_offer do
      action :generate_and_send_offer
      on_success :awaiting_offer_response
      on_error :offer_generation_failed
    end

    # ── Manual: candidate responds to the offer ──
    step :awaiting_offer_response do
      transition :accept, to: :hired
      transition :decline, to: :offer_declined
      transition :negotiate, to: :generate_offer

      timeout :follow_up do
        fire_after {3, :days}
        action :send_offer_follow_up
        repeat true
      end

      timeout :expire, fire_after: {14, :days}, transition_to: :offer_expired
    end

    # ── Terminal states ──
    step :hired, terminal: true
    step :rejected, terminal: true
    step :offer_declined, terminal: true
    step :offer_expired, terminal: true
    step :application_failed, terminal: true
    step :scheduling_failed, terminal: true
    step :offer_generation_failed, terminal: true
    step :escalated, terminal: true
  end

  code_interface do
    define :apply, action: :apply
  end

  # Automatic steps need user-defined actions with business logic.
  # The extension injects transition_state and state_entered_at changes.
  actions do
    defaults [:read]

    create :apply do
      accept [:candidate_name, :candidate_email, :position, :resume_url]
    end

    update :process_application do
      accept []
    end

    update :schedule_phone_screen do
      accept []
    end

    update :schedule_onsite do
      accept []
    end

    update :generate_and_send_offer do
      accept []
    end

    update :send_recruiter_reminder do
      accept []
    end

    update :remind_phone_screen_result do
      accept []
    end

    update :notify_stale_candidate do
      accept []
    end

    update :send_offer_follow_up do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :candidate_name, :string, allow_nil?: false
    attribute :candidate_email, :string, allow_nil?: false
    attribute :position, :string, allow_nil?: false
    attribute :resume_url, :string

    attribute :notes, :string
    attribute :rejection_reason, :string
    attribute :salary, :integer
    attribute :equity, :string
  end
end
