defmodule AshWorkflowDemoWeb.Router do
  use AshWorkflowDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AshWorkflowDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :allow_deck_framing
  end

  # The talk deck can embed the board in an iframe rather than the speaker
  # alt-tabbing to a browser. `put_secure_browser_headers` sets
  # x-frame-options: SAMEORIGIN, and the deck is served on a different port,
  # so it is a different origin and the frame comes up blank. Set
  # ALLOW_FRAMING=1 to drop the header for that one purpose. Leave it unset
  # anywhere the board is reachable by anyone but the speaker.
  defp allow_deck_framing(conn, _opts) do
    if System.get_env("ALLOW_FRAMING") in ~w(1 true),
      do: Plug.Conn.delete_resp_header(conn, "x-frame-options"),
      else: conn
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

    # The sources cited on the slides, as short links the QR codes encode.
    get "/resources/:slug", ResourceRedirectController, :show
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

  # Clarity is a dev-only dependency, so the route exists only in dev.
  if Code.ensure_loaded?(Clarity.Router) do
    scope "/" do
      import Clarity.Router

      pipe_through [:browser, :local_only]
      clarity "/clarity"
    end
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
