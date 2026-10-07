Mix.install([{:eqrcode, "~> 0.2"}])

case System.argv() do
  [url, symbol_path, output_path] ->
    matrix = EQRCode.encode(url, :h)
    background = "#3ba181"
    svg =
      matrix
      |> EQRCode.svg(color: "#090909", background_color: background, width: 900)
      |> String.replace("background-color: #{background}", "background-color: transparent")
      |> String.replace("fill: #{background};", "fill: none;")
    size = EQRCode.Matrix.size(matrix)
    centre = size / 2
    backing_half = 5.0
    symbol_half = 3.5
    symbol_data = symbol_path |> File.read!() |> Base.encode64()

    overlay = """
    <rect x="#{centre - backing_half}" y="#{centre - backing_half}" width="#{backing_half * 2}" height="#{backing_half * 2}" rx="2" fill="#{background}"/>
    <image x="#{centre - symbol_half}" y="#{centre - symbol_half}" width="#{symbol_half * 2}" height="#{symbol_half * 2}" href="data:image/svg+xml;base64,#{symbol_data}"/>
    </svg>
    """

    File.write!(output_path, String.replace(svg, "</svg>", overlay))

  _ ->
    IO.puts(:stderr, "usage: alembic_qr.exs <url> <symbol.svg> <output.svg>")
    System.halt(1)
end
