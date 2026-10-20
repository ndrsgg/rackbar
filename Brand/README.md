# Brand

Direction A, "stacked units": three 1U bars, each with a status LED, the top
one running. Read as a list it is also a menu, which is what the app is.

| File | Use |
| --- | --- |
| `icon-light.svg`, `icon-dark.svg` | App icon, 1024 master: 824 px body at 100 px inset. |
| `icon-mono.svg`, `icon-tint.svg` | Grayscale source and tinted preview, for the Tinted appearance. |
| `icon-small-*.svg` | The pixel-fitted master for 32 px and below: no list lines, glow or highlights. |
| `menubar.svg`, `menubar-problem.svg` | Menu bar template glyph, 18 pt canvas with a 16 pt live area. The app draws it in code (`App/Views/MenuBarIcon.swift`); keep the two in step. |
| `og.html` | Social preview, 1280 × 640. |

`render.sh` turns these into the app icon set, the site's favicon, icons,
`apple-touch-icon.png` and `og.png`. It needs Google Chrome.

## Rules

- **Colour.** Graphite neutrals (`#0E0F11` to `#F5F6F7`). Signal green
  (`#34D17E` on dark, `#147A47` on light) for the running state, "in sync"
  and the wordmark cursor only. Calm blue (`#5B9BFF` / `#2C64CF`) for links,
  selection and focus. Error red (`#FF6259` / `#C42F27`) only next to an
  error, never decorative. On light surfaces always use the ink tone.
- **Type.** Schibsted Grotesk for the wordmark, website, docs and social;
  IBM Plex Mono for commands and hosts there. Inside the app, SF Pro and
  SF Mono.
- **Wordmark.** Schibsted Grotesk Semibold, tracking −3.5%, followed by the
  cursor: one mono underscore in signal green. Drop the cursor at small sizes.
  Lockup: icon height 1.6 × cap height, gap 0.4 × icon.
- **Clear space.** One rack unit around the icon; the cap height of the R
  around the lockup.
- **Minimum sizes.** App icon 16 px, menu glyph 16 pt, lockup 96 px,
  wordmark 64 px.
- **Don't** recolour the status dot, stretch or rotate the icon, add glows or
  outlines, or retype the wordmark.
- Never combine Rackbar with Hetzner logos, their red, clouds, lightning
  bolts, globes or padlocks. Mention Hetzner Cloud in plain text only, and add
  "Not affiliated with Hetzner Online GmbH" wherever the name appears in
  marketing.
