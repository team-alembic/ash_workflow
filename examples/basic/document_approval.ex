defmodule BasicWorkflow.DocumentApproval do
  @moduledoc """
  A simple document approval workflow.

  Flow: start → auto_check → review → approved | rejected

  Demonstrates:
  - Automatic steps (background processing via Oban)
  - Manual steps (human-triggered transitions)
  - Terminal states
  - Basic timeout with a reminder

  ## Usage

      # Author submits a document for approval
      {:ok, workflow} = DocumentApproval.start(%{title: "Q1 Report", author: "alice"})

      # auto_check runs automatically via Oban — validates formatting, scans for issues.
      # On success the workflow moves to :review.

      # A reviewer approves or rejects
      DocumentApproval.approve(workflow, actor: reviewer)
      DocumentApproval.reject(workflow, actor: reviewer)
  """

  use Ash.Resource,
    domain: BasicWorkflow.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshWorkflow]

  workflow do
    step :auto_check do
      action :run_document_checks
      on_success :review
      on_error :check_failed
    end

    step :review do
      manual true

      transition :approve, to: :approved
      transition :reject, to: :rejected

      timeout :reminder, after: {3, :days}, action: :send_review_reminder
    end

    step :approved, terminal: true
    step :rejected, terminal: true
    step :check_failed, terminal: true
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false
    attribute :author, :string, allow_nil?: false
  end

  actions do
    update :run_document_checks do
      accept []
    end

    update :send_review_reminder do
      accept []
    end
  end
end
