defmodule WorkflowTimelineWeb.Router do
  use WorkflowTimelineWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WorkflowTimelineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", WorkflowTimelineWeb do
    pipe_through :browser

    live "/", TimelineLive
  end
end
