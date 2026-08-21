defmodule OrderFulfilment.Order.Pack do
  @moduledoc "Stands in for handing the order to the packing station."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset
end
