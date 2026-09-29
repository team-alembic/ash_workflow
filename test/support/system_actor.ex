defmodule AshWorkflowTest.SystemActor do
  @moduledoc """
  A plain-struct actor that is not an Ash resource, as apps use for internal
  and scheduled work.
  """

  defstruct reason: nil
end
