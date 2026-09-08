defmodule BasicWorkflow.DocumentApproval do
  @moduledoc """
  A simple document approval workflow.

  Flow: auto_check → review → approved | rejected

  Demonstrates:
  - Automatic steps (background processing via Oban)
  - Manual steps (human-triggered transitions)
  - Terminal states
  - Basic timeout with a reminder

  ## Usage

      # Author submits a document for approval. The workflow enters its
      # initial step (:auto_check) as soon as the record is created.
      {:ok, workflow} = DocumentApproval.submit(%{title: "Q1 Report", author: "alice"})

      # auto_check runs automatically via Oban — validates formatting, scans for issues.
      # On success the workflow moves to :review.

      # A reviewer approves or rejects
      DocumentApproval.approve(workflow, actor: reviewer)
      DocumentApproval.reject(workflow, actor: reviewer)
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "document_approvals"
    repo(Example.Repo)
  end

  workflow do
    step :auto_check do
      action :run_document_checks
      on_success :review
      on_error :check_failed
    end

    step :review do
      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :reminder, after: {3, :days}, action: :send_review_reminder
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :check_failed, terminal: true
  end

  code_interface do
    define :submit, action: :submit
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:title, :author]
    end

    update :run_document_checks do
      accept []
    end

    update :send_review_reminder do
      accept []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false
    attribute :author, :string, allow_nil?: false
  end
end
