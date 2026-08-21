defmodule SubscriptionDunning.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource SubscriptionDunning.Subscription
  end
end
