defmodule AshWorkflowDemo.TunnelUrl do
  @moduledoc """
  Single-value store for the cloudflared/ngrok public URL, read by the
  dashboard to render the QR code.

  Seeded from `TUNNEL_URL` at boot. The dashboard used to carry a form for
  pasting one at runtime, which is gone: the URL is known before the server
  starts, and the form was another unauthenticated write on a page the tunnel
  published. `set/1` remains for tests.
  """

  use Agent

  def start_link(_opts) do
    initial = System.get_env("TUNNEL_URL")
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def get, do: Agent.get(__MODULE__, & &1)

  def set(url) when is_binary(url), do: Agent.update(__MODULE__, fn _ -> url end)
end
