defmodule AshWorkflowDemoWeb.Plugs.LocalOnly do
  @moduledoc """
  Serves a route only to the machine running the demo, and answers 404 to
  everyone else.

  This guards the operator pages. The kanban carries **Make the offer**,
  **Veto** and **Reset the board**, and `/timeline` carries undo and redo. All
  of those are one unauthenticated click, and `cloudflared` puts the whole
  app on the public internet, not only `/apply` and `/dbs`.

  The check is on the `Host` header rather than on `conn.remote_ip`.
  `cloudflared` runs on the same machine and proxies to `localhost:4000`, so
  tunnelled requests arrive from `127.0.0.1` exactly like local ones do and
  the remote IP cannot tell them apart. The host name can: locally it is
  `localhost` or a loopback address, and through the tunnel it is the
  `trycloudflare.com` name.

  Set `LOCAL_EXTRA_HOSTS` to a comma-separated list to also allow, say, the
  machine's LAN address when the board is projected from a second screen.

      LOCAL_EXTRA_HOSTS=192.168.1.20:4000,macbook.local:4000 mix phx.server
  """

  import Plug.Conn

  @loopback ~w(localhost 127.0.0.1 ::1 [::1] 0.0.0.0)

  def init(opts), do: opts

  def call(conn, _opts) do
    if local?(conn.host) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Phoenix.Controller.put_view(html: AshWorkflowDemoWeb.ErrorHTML)
      |> Phoenix.Controller.render(:"404")
      |> halt()
    end
  end

  defp local?(host) do
    host = String.downcase(host)

    host in @loopback or host in extra_hosts()
  end

  defp extra_hosts do
    "LOCAL_EXTRA_HOSTS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> strip_port()))
  end

  # `conn.host` never carries the port, but an operator setting this by hand
  # will naturally write the address the way they type it into a browser.
  defp strip_port(host), do: host |> String.split(":") |> hd()
end
