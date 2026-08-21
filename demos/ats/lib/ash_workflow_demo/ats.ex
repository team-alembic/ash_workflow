defmodule AshWorkflowDemo.ATS do
  @moduledoc "The ATS domain — single-slot candidate pipeline."

  use Ash.Domain

  resources do
    resource AshWorkflowDemo.ATS.Candidate do
      define :start, action: :start, args: [:name, :pitch, :avatar_url]
      define :hire, action: :hire
      define :reject, action: :reject
      define :position_filled, action: :position_filled
      define :list_candidates, action: :read
      define :get_candidate, action: :read, get_by: :id
    end
  end
end
