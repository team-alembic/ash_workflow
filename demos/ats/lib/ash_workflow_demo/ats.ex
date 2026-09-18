defmodule AshWorkflowDemo.ATS do
  @moduledoc "The ATS domain — single-slot candidate pipeline."

  use Ash.Domain

  resources do
    resource AshWorkflowDemo.ATS.Candidate do
      define :start, action: :start, args: [:name, :pitch, :avatar_url]
      define :dbs_clear, action: :dbs_clear
      define :dbs_flag, action: :dbs_flag
      define :offer, action: :offer
      define :veto, action: :veto
      define :slot_taken, action: :slot_taken
      define :list_candidates, action: :read
      define :get_candidate, action: :read, get_by: :id
    end

    resource AshWorkflowDemo.ATS.CandidateTransition
  end
end
