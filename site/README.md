# rackbar.app

The marketing page, built with [Astro](https://astro.build) into one static
HTML file: no client framework, no third-party requests. The brand fonts
(Schibsted Grotesk, IBM Plex Mono; both SIL OFL, licences beside them) are
served from `public/fonts`, Latin subset only.

```bash
npm install
npm run dev       # http://localhost:4321
npm run build     # → dist/
```

Pushes to `main` that touch `site/` deploy to GitHub Pages
(`.github/workflows/site.yml`). Paths are absolute, so the page expects to be
served from the root of its domain (rackbar.app, set under Settings → Pages).

## Brand assets

`favicon.svg`, `icon-light.svg`, `icon-dark.svg`, `apple-touch-icon.png` and
`og.png` (1280 × 640, also the GitHub social preview) come from `../Brand`.
Change them there and run `../Brand/render.sh`.

## Image slots

Until a file exists, the page draws an HTML stand-in in its place (the panel
and the SSH tab of Settings, from the demo fleet), so nothing looks broken.

| File | What | Notes |
| --- | --- | --- |
| `public/img/panel.png` | The menu bar panel, dark appearance | 760 px wide (@2x of 380 pt). The panel only, without shadow: the page adds one. |
| `public/img/settings.png` | The Settings window, SSH tab | @2x, without shadow. |

For the screenshots, turn on **Settings → General → Show demo data**, then
`screencapture -o -w panel.png` and click the window (`-o` leaves out the
shadow). The demo fleet is the same one the page's stand-ins and terminal use.
