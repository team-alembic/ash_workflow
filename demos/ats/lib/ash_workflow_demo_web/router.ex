defmodule AshWorkflowDemoWeb.Router do
  use AshWorkflowDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AshWorkflowDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AshWorkflowDemoWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/apply", ApplyLive
    live "/c/:id", CandidateLive
    live "/dbs", DbsBureauLive
    live "/timeline", TimelineLive

    # `/history` and `/rewind` were two pages before the log and the playhead
    # became one. Kept so the README's links and anyone's muscle memory land.
    get "/history", TimelineRedirectController, :show
    get "/rewind", TimelineRedirectController, :show
  end

  scope "/webhooks", AshWorkflowDemoWeb do
    pipe_through :api

    post "/dbs", DbsWebhookController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", AshWorkflowDemoWeb do
  #   pipe_through :api
  # end
end
