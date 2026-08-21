defmodule OrderFulfilment.Order.ChaseSupplier do
  @moduledoc """
  Stands in for nagging the supplier about a backordered item.

  Counting the chases is what lets a test prove the repeating timeout fires more
  than once while the order stays backordered.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.change_attribute(
      changeset,
      :supplier_chases,
      changeset.data.supplier_chases + 1
    )
  end
end
