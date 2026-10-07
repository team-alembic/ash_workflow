# When Time Meets State — OnlySands deck

Edit `deck.md` for slide content and ordering. Visual rules live in `onlysands.css`, and images, GIFs and the video live in `assets/`.

Build from the parent `slides/` directory with `just`. The recipes are listed in `slides/README.md`. `just html` writes `index.html` in this directory, and the PDF and PowerPoint exports are written beside it.

Marp's normal PowerPoint export renders each slide as an image. The experimental editable PowerPoint mode is unsuitable for this deck's image-heavy custom layouts.

## Layout classes

Each slide opens with a `<!-- _class: ... -->` comment that picks its layout from `onlysands.css`:

- `green`, `orange`, `peri` and `dark` set the background colour.
- `blob-green`, `blob-orange` and `blob-peri` add a coloured circle behind the content.
- `code` is a slide built around one code block. Its Elixir fences need a tag, described in `slides/README.md`.
- `person` introduces a character with a portrait from `assets/`.
- `title`, `define`, `qr`, `closing` and `sources` are single-use layouts.

## QR codes

The scripts in `bin/` render the QR codes in `assets/`. `qr.exs` and `plain_qr.exs` give an example command in their header comment. `alembic_qr.exs` takes a URL, the symbol SVG to place in the centre, and the output path.
