{:ok, _} = Application.ensure_all_started(:subscription_dunning)

Ecto.Adapters.SQL.Sandbox.mode(SubscriptionDunning.Repo, :manual)

ExUnit.start()
