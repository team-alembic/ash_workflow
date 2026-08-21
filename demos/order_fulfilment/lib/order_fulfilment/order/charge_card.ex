defmodule OrderFulfilment.Order.ChargeCard do
  @moduledoc """
  Stands in for a payment gateway call.

  Counts attempts as well as succeeding or failing, so a test can show that
  `retry_payment` really does re-run the step rather than skipping it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset =
      Ash.Changeset.change_attribute(
        changeset,
        :payment_attempts,
        changeset.data.payment_attempts + 1
      )

    if changeset.data.card_valid? do
      Ash.Changeset.change_attribute(changeset, :charge_reference, "ch_#{Ash.UUID.generate()}")
    else
      Ash.Changeset.add_error(changeset, field: :card_valid?, message: "card was declined")
    end
  end
end
