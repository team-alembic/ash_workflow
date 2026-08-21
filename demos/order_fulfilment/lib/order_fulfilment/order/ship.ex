defmodule OrderFulfilment.Order.Ship do
  @moduledoc "Stands in for booking a courier, which needs a deliverable address."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.data.address_valid? do
      Ash.Changeset.change_attribute(changeset, :tracking_number, "TRK#{:rand.uniform(999_999)}")
    else
      Ash.Changeset.add_error(changeset,
        field: :address_valid?,
        message: "courier rejected the delivery address"
      )
    end
  end
end
