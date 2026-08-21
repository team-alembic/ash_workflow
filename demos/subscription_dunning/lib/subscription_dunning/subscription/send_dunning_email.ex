defmodule SubscriptionDunning.Subscription.SendDunningEmail do
  @moduledoc """
  Stands in for emailing the customer about their overdue payment.

  Counting the sends is what lets a test prove the repeating timeout fires more
  than once without the subscription leaving `:grace_period`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :dunning_emails_sent,
      changeset.data.dunning_emails_sent + 1
    )
  end
end
