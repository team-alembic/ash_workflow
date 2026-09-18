defmodule SubscriptionDunning.Subscription.SendFinalNotice do
  @moduledoc """
  Stands in for the last warning before cancellation.

  Unlike the dunning email this is a one-shot timeout, so it is the demo's example of
  a one-shot action timeout.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(changeset, :final_notice_sent?, true)
  end
end
