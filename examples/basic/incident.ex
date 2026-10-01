defmodule BasicWorkflow.Incident do
  @moduledoc """
  An incident that a responder escalates or resolves, with undo.

  Flow: triaging → investigating → escalated → resolved

  Demonstrates:
  - Undo: `escalate` and `resolve` are `undoable?: true`, so the generated
    `undo` action can rewind them for up to an hour
  - A recurring status update with `every`
  - An escalation timeout
  - An automatic step with an error route

  Undo needs a transition log, which is `BasicWorkflow.IncidentTransition`.
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "incidents"
    repo(Example.Repo)
  end

  workflow do
    transition_log BasicWorkflow.IncidentTransition

    undo do
      within {1, :hours}
    end

    step :triaging do
      action :classify_severity
      on_success :investigating
      on_error :triage_failed
    end

    step :investigating do
      transition :escalate, to: :escalated, undoable?: true
      transition :resolve, to: :resolved, undoable?: true

      every :status_update do
        interval {1, :hours}
        action :send_status_update
      end

      timeout :auto_escalate, fire_after: {4, :hours}, transition_to: :escalated
    end

    step :escalated do
      transition :resolve, to: :resolved, undoable?: true
    end

    step :resolved, terminal: true
    step :triage_failed, terminal: true
  end

  code_interface do
    define :report, action: :report
  end

  actions do
    defaults [:read]

    create :report do
      accept [:title]
    end

    update :classify_severity do
      accept []
    end

    update :send_status_update do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false
  end
end
