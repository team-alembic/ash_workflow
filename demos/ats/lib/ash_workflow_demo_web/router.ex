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

  # The operator's own machine. `cloudflared` publishes the whole app, not
  # only the two pages the audience needs, and these carry every write button
  # in the demo.
  pipeline :local_only do
    plug AshWorkflowDemoWeb.Plugs.LocalOnly
  end

  # What the audience reaches through the tunnel. Applying is the point, and
  # the bureau portal is meant to be worked from a second phone.
  scope "/", AshWorkflowDemoWeb do
    pipe_through :browser

    live "/apply", ApplyLive
    live "/c/:id", CandidateLive
    live "/dbs", DbsBureauLive
  end

  scope "/", AshWorkflowDemoWeb do
    pipe_through [:browser, :local_only]

    live "/", DashboardLive
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
