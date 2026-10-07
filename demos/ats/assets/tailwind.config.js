// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/ash_workflow_demo_web.ex",
    "../lib/ash_workflow_demo_web/**/*.*ex"
  ],
  theme: {
    extend: {
      // The talk deck's palette, kept in step with
      // slides/2026-ashconf-when-time-meets-state/onlysands.css so the demo on the
      // projector and the slides around it read as one company.
      colors: {
        cream: "#fff6df",   // --c, the page background
        ink: "#090909",     // --i, body text and hard borders/shadows
        dark: "#100d18",    // the deck's `.dark` section background; reserved
                             // for the rejected state, since the deck carries
                             // no red for a rejection to borrow
        paper: "#ffffff",   // a card raised off the cream page
        well: "#f6ecc9",    // a panel recessed into a card, one shade below cream
        muted: "#6b6558",   // secondary text, dark enough to read from the
                             // back of a projected room
        line: "#e5d8ab",    // hairline dividers
        green: "#3ba181",
        orange: "#c95b05",
        peri: "#8fa1ff",
        amber: "#f2b540",   // the brandmark pill's colour; the app's one accent
      },
      fontFamily: {
        // The deck sets its headings in Georgia and everything else in
        // Courier New. `font-sans` (the body default) carries the Courier
        // stack; headings opt into `font-serif` for the Georgia one.
        sans: ["Courier New", "Courier", "monospace"],
        serif: ["Georgia", "Times New Roman", "serif"],
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embeds Heroicons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
