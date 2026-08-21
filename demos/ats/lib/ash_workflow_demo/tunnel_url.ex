defmodule AshWorkflowDemo.TunnelUrl do
  @moduledoc """
  Single-value store for the cloudflared/ngrok public URL. Read by the
  dashboard to render the QR code. Settable at runtime for live updates.
  """

  use Agent

  def start_link(_opts) do
    initial = System.get_env("TUNNEL_URL")
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  def get, do: Agent.get(__MODULE__, & &1)

  def set(url) when is_binary(url) do
    Agent.update(__MODULE__, fn _ -> url end)
    Phoenix.PubSub.broadcast(AshWorkflowDemo.PubSub, "tunnel_url", {:tunnel_url_changed, url})
  end
end
