defmodule SubscriptionDunning.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SubscriptionDunning.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:subscription_dunning, :ash_domains),
         Application.fetch_env!(:subscription_dunning, Oban)
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SubscriptionDunning.Supervisor)
  end
end
