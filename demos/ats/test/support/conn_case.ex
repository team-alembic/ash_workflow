defmodule AshWorkflowDemoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AshWorkflowDemoWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AshWorkflowDemoWeb.Endpoint

      use AshWorkflowDemoWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AshWorkflowDemoWeb.ConnCase

      # Workflow-driving helpers: a LiveView test that needs a reviewable
      # candidate has to get one the way the app does.
      import AshWorkflowDemo.DataCase,
        only: [
          run_workflow_triggers: 1,
          ready_for_hr_decision: 1,
          ready_for_lead_decision: 1,
          reload: 1,
          age_by: 3,
          set_datetime: 3
        ]
    end
  end

  setup tags do
    AshWorkflowDemo.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
