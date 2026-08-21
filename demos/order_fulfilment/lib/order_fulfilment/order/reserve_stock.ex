defmodule OrderFulfilment.Order.ReserveStock do
  @moduledoc "Stands in for a warehouse stock reservation."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.data.stock_available? do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :stock_available?,
        message: "insufficient stock to reserve"
      )
    end
  end
end
