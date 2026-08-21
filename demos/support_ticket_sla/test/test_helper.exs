{:ok, _} = Application.ensure_all_started(:support_ticket_sla)

Ecto.Adapters.SQL.Sandbox.mode(SupportTicketSla.Repo, :manual)

ExUnit.start()
