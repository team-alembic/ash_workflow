defmodule AshWorkflowDemoWeb.TimelineRedirectController do
  @moduledoc """
  Sends the retired `/history` and `/rewind` paths to `/timeline`, which now
  serves both the log and the playhead.
  """

  use AshWorkflowDemoWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/timeline")
  end
end
