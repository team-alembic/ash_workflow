defmodule OrderFulfilment.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OrderFulfilment.Repo,
      {Oban,
       AshOban.config(
         Application.fetch_env!(:order_fulfilment, :ash_domains),
         Application.fetch_env!(:order_fulfilment, Oban)
       )}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OrderFulfilment.Supervisor)
  end
end
