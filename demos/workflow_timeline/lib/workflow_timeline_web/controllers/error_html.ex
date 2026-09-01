defmodule WorkflowTimelineWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by the endpoint in case of errors on HTML requests.
  """
  use WorkflowTimelineWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
