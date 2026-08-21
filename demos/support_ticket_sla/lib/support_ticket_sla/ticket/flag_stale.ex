defmodule SupportTicketSla.Ticket.FlagStale do
  @moduledoc "Stands in for periodically re-surfacing a ticket rotting in the backlog."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(changeset, :stale_flags, changeset.data.stale_flags + 1)
  end
end
