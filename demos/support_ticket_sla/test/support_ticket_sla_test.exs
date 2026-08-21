defmodule SupportTicketSla.TicketTest do
  @moduledoc """
  Exercises one transition that leads to three different places depending on the
  record, and one transition name that means different things in different steps.
  """
  use SupportTicketSla.DataCase

  alias SupportTicketSla.Ticket

  defp agent, do: %{id: Ash.UUID.generate(), role: :agent}
  defp manager, do: %{id: Ash.UUID.generate(), role: :manager}

  defp open(priority) do
    Ticket.open!(%{subject: "It is broken", priority: priority, requester_email: "a@b.co"})
  end

  defp reload(ticket), do: Ash.get!(Ticket, ticket.id, authorize?: false)

  describe "priority-based triage" do
    test "an urgent ticket routes to the urgent queue" do
      assert Ticket.triage!(open(:urgent), actor: agent()).state == :urgent_queue
    end

    test "a normal ticket routes to the standard queue" do
      assert Ticket.triage!(open(:normal), actor: agent()).state == :standard_queue
    end

    test "a low priority ticket routes to the backlog" do
      assert Ticket.triage!(open(:low), actor: agent()).state == :backlog
    end

    test "one action serves all three routes" do
      # The caller does not choose the destination — the record does.
      for {priority, expected} <- [urgent: :urgent_queue, normal: :standard_queue, low: :backlog] do
        assert Ticket.triage!(open(priority), actor: agent()).state == expected
      end
    end

    test "only agents may triage" do
      assert {:error, error} = Ticket.triage(open(:normal), actor: %{id: "x", role: :customer})
      assert Exception.message(error) =~ "forbidden"
    end
  end

  describe "the same transition name meaning different things" do
    test "escalating from a queue sends the ticket to a manager" do
      ticket = open(:urgent) |> Ticket.triage!(actor: agent())

      assert Ticket.escalate!(ticket, actor: agent()).state == :escalated
    end

    test "escalating from the backlog promotes it into the standard queue instead" do
      ticket = open(:low) |> Ticket.triage!(actor: agent())
      assert ticket.state == :backlog

      # Same verb, different meaning — routed by the ticket's current state.
      assert Ticket.escalate!(ticket, actor: agent()).state == :standard_queue
    end

    test "escalate is a single action across all three steps" do
      assert Ash.Resource.Info.action(Ticket, :escalate)
    end
  end

  describe "SLA deadlines differ by queue" do
    test "an urgent ticket breaches after an hour" do
      ticket = open(:urgent) |> Ticket.triage!(actor: agent())

      age_by(ticket, 2, :hour)
      run_workflow_triggers(Ticket)

      assert reload(ticket).state == :escalated
    end

    test "a standard ticket is untouched at the urgent deadline" do
      ticket = open(:normal) |> Ticket.triage!(actor: agent())

      age_by(ticket, 2, :hour)
      run_workflow_triggers(Ticket)

      assert reload(ticket).state == :standard_queue
    end

    test "a standard ticket breaches after two days" do
      ticket = open(:normal) |> Ticket.triage!(actor: agent())

      age_by(ticket, 3, :day)
      run_workflow_triggers(Ticket)

      assert reload(ticket).state == :escalated
    end

    test "the urgent queue warns before it breaches, without changing state" do
      ticket = open(:urgent) |> Ticket.triage!(actor: agent())

      age_by(ticket, 40, :minute)
      run_workflow_triggers(Ticket)

      warned = reload(ticket)
      assert warned.sla_warnings_sent == 1
      assert warned.state == :urgent_queue
    end
  end

  describe "untriaged tickets" do
    test "an unattended ticket escalates regardless of priority" do
      ticket = open(:low)

      age_by(ticket, 5, :hour)
      run_workflow_triggers(Ticket)

      assert reload(ticket).state == :escalated
    end
  end

  describe "backlog" do
    test "a stale backlog ticket is re-flagged repeatedly without moving" do
      ticket = open(:low) |> Ticket.triage!(actor: agent())

      age_by(ticket, 31, :day)
      run_workflow_triggers(Ticket)
      assert reload(ticket).stale_flags == 1
      assert reload(ticket).state == :backlog

      age_by(ticket, 31, :day)
      run_workflow_triggers(Ticket)
      assert reload(ticket).stale_flags == 2
    end
  end

  describe "escalated tickets" do
    setup do
      ticket =
        open(:urgent)
        |> Ticket.triage!(actor: agent())
        |> Ticket.escalate!(actor: agent())

      %{ticket: ticket}
    end

    test "an agent cannot resolve an escalation", ctx do
      assert {:error, error} =
               Ticket.manager_resolve(ctx.ticket, %{resolution: "fixed"}, actor: agent())

      assert Exception.message(error) =~ "forbidden"
    end

    test "the agents' resolve does not reach an escalated ticket", ctx do
      # :resolve is not declared on :escalated, so the state machine refuses it
      # regardless of who is asking.
      assert {:error, _} = Ticket.resolve(ctx.ticket, %{resolution: "fixed"}, actor: manager())
    end

    test "a manager can resolve it", ctx do
      resolved = Ticket.manager_resolve!(ctx.ticket, %{resolution: "fixed"}, actor: manager())

      assert resolved.state == :resolved
      assert resolved.resolution == "fixed"
    end

    test "a manager can send it back to the standard queue", ctx do
      assert Ticket.reassign!(ctx.ticket, actor: manager()).state == :standard_queue
    end
  end

  describe "resolving from a queue" do
    test "an agent resolves their own queue's ticket" do
      resolved =
        open(:normal)
        |> Ticket.triage!(actor: agent())
        |> Ticket.resolve!(%{resolution: "restarted it"}, actor: agent())

      assert resolved.state == :resolved
    end

    test "a resolved ticket is terminal" do
      resolved =
        open(:normal)
        |> Ticket.triage!(actor: agent())
        |> Ticket.resolve!(%{resolution: "done"}, actor: agent())

      assert {:error, _} = Ticket.escalate(resolved, actor: agent())
    end
  end
end
