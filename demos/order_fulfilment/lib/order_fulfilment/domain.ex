defmodule OrderFulfilment.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource OrderFulfilment.Order
  end
end
