defmodule AshWorkflowTest.DeckDomain do
  @moduledoc """
  The domain for the resources `AshWorkflowTest.DeckBlocks` compiles out of the
  slide deck.

  Those resources are built at test time, one per code block, so they cannot be
  listed here. `allow_unregistered? true` is what lets them declare this domain
  without each one having to be named.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end
