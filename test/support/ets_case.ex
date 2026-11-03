defmodule AshWorkflowTest.EtsCase do
  @moduledoc """
  Case template for tests whose workflow resources use the ETS data layer.

  `AshWorkflow.Scheduler.Oban` queues an Oban job when a record enters an
  automatic step, and Oban writes that job to Postgres even when the record
  lives in ETS. Each test checks out its own sandbox connection, so these cases
  can stay async.
  """
  use ExUnit.CaseTemplate

  alias AshWorkflowTest.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)
  end
end
