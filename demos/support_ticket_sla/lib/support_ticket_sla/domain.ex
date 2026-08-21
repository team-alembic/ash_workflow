defmodule SupportTicketSla.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource SupportTicketSla.Ticket
  end
end
