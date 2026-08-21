{:ok, _} = Application.ensure_all_started(:order_fulfilment)

Ecto.Adapters.SQL.Sandbox.mode(OrderFulfilment.Repo, :manual)

ExUnit.start()
