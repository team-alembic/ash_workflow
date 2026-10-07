defmodule AshWorkflowDemo.ATS.Candidate do
  @moduledoc """
  The only resource in the demo. Represents a conference attendee who
  submitted themselves as a candidate for the single open role.

  Three parties move a candidate along and only one of them is in the room.
  Janine in HR and Steve the engineering lead are both played by the workflow
  itself: Janine answers within seven seconds, Steve's delay is drawn per
  candidate and fans out. The bureau answers over HTTP from a different
  screen, on its own short random clock when nobody works the portal, and
  sometimes fails its first attempt and gets retried. El Jefe is the only
  human with a button.
  """

  use Ash.Resource,
    domain: AshWorkflowDemo.ATS,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban],
    notifiers: [AshWorkflowDemo.ATS.Candidate.Notifier]

  postgres do
    table "candidates"
    repo AshWorkflowDemo.Repo

    custom_indexes do
      # The correlation key the bureau replies against. Unique because
      # DbsBureau.find_by_reference/1 reads one row and has no other guarantee
      # that it is the only one.
      index [:dbs_reference], unique: true, where: "dbs_reference is not null"
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :pitch, :string, allow_nil?: false, public?: true
    attribute :avatar_url, :string, allow_nil?: false, public?: true

    # Both are drawn per candidate on :start, which is what lets a whole room
    # applying at once fan out across the column instead of answering in
    # lockstep.
    attribute :hr_delay_seconds, :integer, public?: true
    attribute :lead_delay_seconds, :integer, public?: true

    # The deadlines themselves, stamped on entry to the step they govern.
    # These would read better as calculations over state_entered_at plus the
    # delay, which is what `field` documents as supported. AshWorkflow's
    # Precise scheduler filters on such a calculation correctly but then arms
    # its timer off an unloaded value and crashes, so they are real columns.
    attribute :hr_respond_after, :utc_datetime_usec, public?: true
    attribute :lead_respond_after, :utc_datetime_usec, public?: true
    attribute :dbs_respond_after, :utc_datetime_usec, public?: true

    attribute :score, :integer, public?: true
    attribute :score_reason, :string, public?: true

    attribute :lead_score, :integer, public?: true
    attribute :lead_note, :string, public?: true

    # The bureau's reference, not ours. Everything the bureau sends back is
    # correlated on this rather than on :id.
    attribute :dbs_reference, :string, public?: true

    # nil means the check came back clear. Anything else is what they found.
    attribute :dbs_offence, :string, public?: true

    # Whether this candidate's bureau call fails on its first attempt, drawn
    # on submission so the failure is scripted rather than a coin flip at
    # stage time. See AshWorkflowDemo.ATS.Candidate.BureauReturnsResult.
    attribute :bureau_flaky?, :boolean, default: false, public?: true
    attribute :bureau_attempts, :integer, default: 0, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    create :start do
      accept [:name, :pitch, :avatar_url]
      change AshWorkflowDemo.ATS.Candidate.SetResponseDelays
    end

    update :dbs_clear do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.StartLeadClock
    end

    update :dbs_flag do
      accept [:dbs_offence]
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.StartLeadClock
    end

    update :record_hr_screen do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.JanineScreens
      change AshWorkflowDemo.ATS.Candidate.StartBureauClock
    end

    # The retry counter's own action, separate from :record_bureau_result so
    # it can be bumped from inside that action's change before a raise there
    # aborts everything else on the changeset. See BureauReturnsResult.
    update :bump_bureau_attempts do
      accept [:bureau_attempts]
    end

    # Every way into :lead_interview runs one of these three, which is the only
    # reason :bureau_result exists as a step: a resource-level change would
    # also apply to the generated __timeout_* actions, and those must be
    # atomic.
    update :record_bureau_result do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.BureauReturnsResult
      change AshWorkflowDemo.ATS.Candidate.StartLeadClock
    end

    update :record_lead_interview do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.SteveInterviews
    end

    update :offer do
      accept []
      require_atomic? false
      change AshWorkflowDemo.ATS.Candidate.Cascade
    end
  end

  workflow do
    # Every deadline here is shorter than a minute, which is more than cron can
    # poll for. Precise arms a timer per deadline instead of polling, so they
    # need no self_scheduled? flag and no hand-rolled ticker.
    # scheduler AshWorkflow.Scheduler.Precise

    transition_log AshWorkflowDemo.ATS.CandidateTransition

    # Matches the talk script: a mis-click has half an hour to get corrected
    # before the window closes.
    undo do
      within {30, :minutes}
    end

    # Janine is reading the pitch. Nothing runs while the candidate waits here;
    # the step's only exit is her own deadline.
    step :hr_screen do
      transition :slot_taken, to: :rejected

      timeout :janine_responds do
        fire_at :hr_respond_after
        transition_to :hr_decision
      end
    end

    # Janine's verdict. Instantaneous, so no card ever visibly rests here —
    # the board files it under the HR screen column.
    step :hr_decision do
      action :record_hr_screen

      on_success :background_check, when: expr(score >= 4)
      on_success :rejected

      on_error :rejected
    end

    # The one step waiting on another system. The correlation that resumes it
    # lives in AshWorkflowDemo.ATS.DbsBureau rather than in this block, because
    # the workflow has no way to say "wait for an event keyed on
    # :dbs_reference". See issue #61.
    step :background_check do
      transition :dbs_clear, to: :lead_interview, undoable?: true
      transition :dbs_flag, to: :lead_interview, accept: [:dbs_offence], undoable?: true
      transition :slot_taken, to: :rejected

      # Short and random, drawn per candidate on `:record_hr_screen`. Long
      # enough that a person can pick up the other screen and answer on it.
      # Nobody has to: when it fires, the bureau answers for itself.
      timeout :bureau_responds do
        fire_after {1, :seconds}
        field :dbs_respond_after
        transition_to :bureau_result
      end
    end

    step :bureau_result do
      action :record_bureau_result
      on_success :lead_interview
      on_error :lead_interview

      # The bureau is the one call in this demo that stands in for a flaky
      # third-party API: BureauReturnsResult fails a flaky candidate's first
      # attempt on purpose, and this is what retries it rather than routing
      # straight to on_error.
      retry do
        max_attempts 3
        backoff {2, :seconds}
      end
    end

    step :lead_interview do
      transition :slot_taken, to: :rejected

      timeout :steve_responds do
        fire_after {1, :seconds}
        field :lead_respond_after
        transition_to :lead_decision
      end
    end

    step :lead_decision do
      action :record_lead_interview

      on_success :final_approval, when: expr(lead_score >= 4)
      on_success :rejected

      on_error :rejected
    end

    # The only step with a human on the other side of it.
    #
    # Undo resolves by (from_state, to_state) edge, not by which named
    # transition wrote the row — AshWorkflow.Info.undoable_edge?/3 only ever
    # sees the pair. :veto and :slot_taken both land on :final_approval ->
    # :rejected, so a bystander swept here by the offer cascade reads as
    # undoable too, purely because :veto shares that edge. See
    # candidate_transition_test.exs's "shares :veto's undoable edge" test.
    step :final_approval do
      transition :offer, to: :hired, undoable?: true
      transition :veto, to: :rejected, undoable?: true
      transition :slot_taken, to: :rejected

      timeout :jefe_no_answer, fire_after: {45, :seconds}, transition_to: :rejected
    end

    step :hired, terminal: true
    step :rejected, terminal: true
  end
end
