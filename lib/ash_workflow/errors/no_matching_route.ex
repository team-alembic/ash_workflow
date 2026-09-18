defmodule AshWorkflow.Errors.NoMatchingRoute do
  @moduledoc """
  Returned (or raised) when an automatic step's action succeeds but none of
  its `on_success` routes match the resulting record.

  `AshWorkflow.Verifiers.ValidateWorkflow` rejects a step whose `on_success`
  is not statically exhaustive — no trailing unconditional entry — and which
  also declares no `on_error`, so this error is only ever returned to a
  caller when `on_error` is declared, added to the changeset so the step's
  standard error path handles it. It is raised directly on a step that
  somehow reaches this with no `on_error`, since there is then nowhere for
  the record to go.
  """
  use Splode.Error, fields: [:resource, :step, :action], class: :invalid

  @impl true
  def message(error) do
    "No on_success route matched for step :#{error.step} (action :#{error.action}) on " <>
      "#{inspect(error.resource)}. The action succeeded, but none of the step's on_success " <>
      "conditions matched the resulting record."
  end
end
