defmodule SupportTicketSla.Ticket.WarnSla do
  @moduledoc "Stands in for warning the on-call agent that an SLA is about to breach."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :sla_warnings_sent,
      changeset.data.sla_warnings_sent + 1
    )
  end
end
