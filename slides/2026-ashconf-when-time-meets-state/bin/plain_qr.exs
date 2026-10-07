# Renders a URL as a plain SVG QR for the closing slide's link cards. No centre
# overlay here, unlike bin/qr.exs: these codes are small on the slide, and the
# error-correction budget is better spent on being scannable from the back of
# the room.
#
#   elixir bin/plain_qr.exs https://github.com/team-alembic/ash_workflow assets/github-qr.svg

Mix.install([{:eqrcode, "~> 0.2"}])

ink = "#090909"
cream = "#fff6df"

case System.argv() do
  [url, out] ->
    matrix = EQRCode.encode(url, :m)
    svg = EQRCode.svg(matrix, color: ink, background_color: cream, width: 900)
    File.write!(out, svg)
    IO.puts("#{url} -> #{out} (#{EQRCode.Matrix.size(matrix)} modules, level :m)")

  _ ->
    IO.puts(:stderr, "usage: plain_qr.exs <url> <out.svg>")
    System.halt(1)
end
