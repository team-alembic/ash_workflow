defmodule SupportTicketSla.Ticket do
  @moduledoc """
  A support ticket that is triaged, worked, and escalated if it misses its SLA.

  This is the demo for **one transition leading to different places depending on
  the record**, and for the same transition name meaning different things in
  different steps.

  Triage sends a ticket down one of three paths based on its priority, using
  conditional routes:

      transition :triage do
        route :urgent_queue,   when: expr(priority == :urgent)
        route :standard_queue, when: expr(priority == :normal)
        route :backlog,        when: expr(priority == :low)
      end

  And `:escalate` is declared on three different steps with three different
  targets. AshWorkflow merges those into a single `:escalate` action that routes
  by the ticket's current state, so callers do not need to know which step a
  ticket is in.
  """

  use Ash.Resource,
    domain: SupportTicketSla.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshWorkflow, AshOban]

  postgres do
    table "tickets"
    repo SupportTicketSla.Repo
  end

  workflow do
    step :triaging do
      policy actor_attribute_equals(:role, :agent)

      # One action, three destinations, chosen from the ticket itself.
      transition :triage do
        route :urgent_queue, when: expr(priority == :urgent)
        route :standard_queue, when: expr(priority == :normal)
        route :backlog, when: expr(priority == :low)
      end

      # An unattended ticket is a support failure regardless of priority.
      timeout :untriaged, fire_after: {4, :hours}, transition_to: :escalated
    end

    step :urgent_queue do
      policy actor_attribute_equals(:role, :agent)

      transition :resolve, to: :resolved, accept: [:resolution]
      transition :escalate, to: :escalated

      timeout :sla_breach, fire_after: {1, :hours}, transition_to: :escalated
      timeout :warn, fire_after: {30, :minutes}, action: :warn_sla_approaching
    end

    step :standard_queue do
      policy actor_attribute_equals(:role, :agent)

      transition :resolve, to: :resolved, accept: [:resolution]
      transition :escalate, to: :escalated

      timeout :sla_breach, fire_after: {2, :days}, transition_to: :escalated
    end

    step :backlog do
      policy actor_attribute_equals(:role, :agent)

      transition :resolve, to: :resolved, accept: [:resolution]
      # From the backlog, escalating means promotion into the standard queue
      # rather than going to a manager — the same verb, a different meaning.
      transition :escalate, to: :standard_queue

      every :stale do
        interval {30, :days}
        action :flag_stale
      end
    end

    step :escalated do
      # Only a manager can close out an escalation. The resolve transition is
      # named differently from the agents' `:resolve` on purpose: steps sharing
      # a transition name merge into one action, so one policy would have to
      # serve both roles. AshWorkflow rejects that at compile time.
      policy actor_attribute_equals(:role, :manager)

      transition :manager_resolve, to: :resolved, accept: [:resolution]
      transition :reassign, to: :standard_queue
    end

    step :resolved, terminal: true
  end

  code_interface do
    define :open, action: :open
  end

  actions do
    defaults [:read]

    create :open do
      accept [:subject, :priority, :requester_email]
    end

    update :warn_sla_approaching do
      accept []
      require_atomic? false
      change SupportTicketSla.Ticket.WarnSla
    end

    update :flag_stale do
      accept []
      require_atomic? false
      change SupportTicketSla.Ticket.FlagStale
    end
  end

  policies do
    policy action(:open) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :requester_email, :string, allow_nil?: false, public?: true

    attribute :priority, :atom,
      constraints: [one_of: [:urgent, :normal, :low]],
      allow_nil?: false,
      default: :normal,
      public?: true

    attribute :resolution, :string, public?: true
    attribute :sla_warnings_sent, :integer, allow_nil?: false, default: 0, public?: true
    attribute :stale_flags, :integer, allow_nil?: false, default: 0, public?: true
  end
end
