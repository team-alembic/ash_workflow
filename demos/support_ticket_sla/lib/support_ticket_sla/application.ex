defmodule SupportTicketSla.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SupportTicketSla.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:support_ticket_sla, :ash_domains),
         Application.fetch_env!(:support_ticket_sla, Oban)
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SupportTicketSla.Supervisor)
  end
end
