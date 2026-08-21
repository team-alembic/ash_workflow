defmodule DocumentApproval.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DocumentApproval.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:document_approval, :ash_domains),
         Application.fetch_env!(:document_approval, Oban)
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DocumentApproval.Supervisor)
  end
end
