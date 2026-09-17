defmodule AshWorkflowDemo.ATS.CandidateTransition do
  @moduledoc """
  The transition log for `AshWorkflowDemo.ATS.Candidate`.

  One row per workflow event — every automatic step, manual transition,
  timeout, error path, and the `:initial` row a candidate is created with.
  This is what `/history` and `/rewind` read instead of the candidate's
  current `state` column.

  Scaffolded by `mix ash_workflow.gen.transition_log` and hand-adjusted: the
  generated `:workflow` relationship is renamed to `:candidate` to match this
  domain's naming, and the table name it picked (`candidates_transitions`,
  from the `Candidate` resource's own `candidates` table) is kept as-is.
  """

  use Ash.Resource,
    domain: AshWorkflowDemo.ATS,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "candidates_transitions"
    repo AshWorkflowDemo.Repo

    custom_indexes do
      index [:candidate_id, :occurred_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :from_state, :atom, public?: true
    attribute :to_state, :atom, allow_nil?: false, public?: true
    attribute :transition_name, :atom, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :triggered_by, :atom, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :candidate, AshWorkflowDemo.ATS.Candidate,
      allow_nil?: false,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true

    # Set on an undo row, pointing at the row it reverses. Undo appends
    # rather than mutating, so the reversed row stays exactly as written
    # and both readings of history stay derivable from the same rows.
    belongs_to :undoes, __MODULE__,
      allow_nil?: true,
      public?: true,
      attribute_public?: true,
      attribute_writable?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :candidate_id,
        :undoes_id,
        :from_state,
        :to_state,
        :transition_name,
        :occurred_at,
        :triggered_by
      ]
    end
  end
end
