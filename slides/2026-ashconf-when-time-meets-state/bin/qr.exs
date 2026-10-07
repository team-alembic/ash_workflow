# Renders the ATS demo README URL as an SVG for the QR slide. The deck prints one fixed
# address, so it needs re-rendering if the demo README moves.
#
#   elixir bin/qr.exs https://github.com/team-alembic/ash_workflow/tree/main/demos/ats assets/demo-qr.svg
#
# Encoded at error-correction level :h, which tolerates 30% of the code being
# unreadable. That budget is what pays for the OnlySands mark sitting in the
# middle: the overlay covers roughly 7% of the modules, well inside it. The
# three corner finder patterns are never covered, because a scanner locates
# the code with those before it reads anything.

Mix.install([{:eqrcode, "~> 0.2"}])

ink = "#090909"
cream = "#fff6df"
amber = "#f2b540"

case System.argv() do
  [url, out] ->
    matrix = EQRCode.encode(url, :h)
    svg = EQRCode.svg(matrix, color: ink, background_color: cream, width: 900)

    size = EQRCode.Matrix.size(matrix)
    centre = size / 2
    half = 4.6

    overlay = """
    <rect x="#{centre - half}" y="#{centre - half}" width="#{half * 2}" height="#{half * 2}" rx="1.6" fill="#{cream}"/>
    <rect x="#{centre - half + 0.5}" y="#{centre - 2.0}" width="#{half * 2 - 1.0}" height="4.0" rx="2.0" fill="#{ink}"/>
    <text x="#{centre}" y="#{centre + 0.95}" text-anchor="middle" fill="#{amber}" font-family="Arial,Helvetica,sans-serif" font-weight="900" font-size="2.7" letter-spacing="-0.05">OS</text>
    </svg>
    """

    File.write!(out, String.replace(svg, "</svg>", overlay))
    IO.puts("#{url} -> #{out} (#{size}x#{size} modules, level :h)")

  _ ->
    IO.puts(:stderr, "usage: qr.exs <url> <out.svg>")
    System.halt(1)
end
