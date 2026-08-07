# Neo Theme Deployment Guide

The interface of this deployment uses the Neo design system (https://neo.wiwo.me)
rather than the stock Huly look. This guide explains where the theme lives and how
to ship a change to it.

## Where the theme lives

The theme is **source code**, not a deployment-time patch. It lives in the frontend
fork at https://github.com/WiWO-Creators/wiwo.ops-front, mainly under
`packages/theme/`:

| Path | Contents |
|---|---|
| `styles/_vars.scss` | Neo brand palette, motion tokens, border radii |
| `styles/_colors.scss` | Per-theme colors (`*`, `.theme-dark`, `.theme-light`) |
| `styles/_lumia-colors.scss` | Per-theme colors for the newer `--global-*` token set |
| `styles/_neo-fonts.scss` | `@font-face` rules — generated, do not hand-edit |
| `fonts/neo/` | Self-hosted `.woff2` files (Plus Jakarta Sans, Outfit, Tomorrow) |
| `scripts/build-neo-fonts.js` | Regenerates the two entries above |
| `scripts/check-contrast.js` | WCAG AA check over the compiled token pairs |

Huly drives every color, radius and shadow through CSS custom properties, so
changing these files restyles the whole application without touching markup or
behaviour. A few components carried hardcoded brand colors and were adjusted at
the component level: the login and onboarding panels
(`plugins/login-resources`, `plugins/onboard-resources`) and the theme picker
preview (`packages/ui`).

## Branding assets

The icon is a WiWO "W" monogram drawn with the Neo primary gradient
(`#3BFF00 → #4242FF`) on the Neo ink background (`#292929`). The vector source is
`dev/prod/public/huly/favicon.svg` in the fork — everything else is rasterised
from it with `rsvg-convert`:

```bash
cd dev/prod/public/huly
for s in 192 256 512 1024 1600; do rsvg-convert -w $s -h $s favicon.svg -o icon-$s.png; done
rsvg-convert -w 180 -h 180 favicon.svg -o apple-touch-icon.png
```

`favicon.ico` bundles 16/32/48 px PNGs; regenerate it the same way and repack with
any ICO tool. The login screen uses a separate borderless variant of the same
monogram in `plugins/login-resources/src/components/icons/LoginIcon.svelte`, tuned
for the dark login panel.

The directory is still named `huly/` because `branding.json` and the deployment
key reference that path; only its contents are WiWO.

The window title comes from `TITLE` in `huly.conf` (`WiWO Ops` by default). The
`branding.json` shipped in the fork only affects the local dev server.

## Building the frontend image

This repository does not build the frontend. Do it in a checkout of the fork:

```bash
node common/scripts/install-run-rush.js install
node common/scripts/install-run-rush.js build
cd pods/front && rushx bundle && rushx package
docker build -t wiwo/front:<tag> .
```

`rushx package` copies `dev/prod/dist` and `dev/prod/public/*` into the image, so
the compiled theme and the branding assets travel with it.

Push the image to a registry the server can reach, or load it there directly with
`docker save` / `docker load`.

## Pointing this deployment at the image

Set `FRONT_IMAGE` in `huly.conf`:

```
FRONT_IMAGE=wiwo/front:<tag>
```

Then recreate only the frontend container:

```bash
docker compose up -d --force-recreate front
```

If `FRONT_IMAGE` is unset, `compose.yml` falls back to the upstream prebuilt
`hardcoreeng/front:${HULY_VERSION}` — which has the stock Huly look, not Neo.
That fallback is the quickest way to check whether a visual bug comes from the
theme or from Huly itself.

## Iterating on colors

Unlike the previous stylesheet-injection setup, colors are now compiled into the
bundle: editing a value means a rebuild. For fast iteration, run the dev server in
the fork (`cd dev/prod && rushx dev-server`) — it hot-reloads SCSS — and only
build an image once the result is settled.

## Checking contrast after a color change

Both themes are meant to hold WCAG AA. After editing colors, from `packages/theme`:

```bash
npx sass --load-path=styles styles/global.scss /tmp/theme.css
node scripts/check-contrast.js /tmp/theme.css
```

It exits non-zero if any text/surface pair drops below its threshold.

## Updating fonts

`styles/_neo-fonts.scss` and `fonts/neo/` are generated from the Google Fonts API.
To change weights or add a subset, edit `GOOGLE_FONTS_CSS_URL` in
`scripts/build-neo-fonts.js` and regenerate, from `packages/theme`:

```bash
node scripts/build-neo-fonts.js fonts/neo styles/_neo-fonts.scss
```

The generated `@font-face` rules deliberately omit `local()`: Plus Jakarta Sans and
Outfit ship as variable fonts, and a static copy installed on the viewer's machine
would otherwise win and break intermediate weights.

## Merging upstream Huly

The theme changes are concentrated in `packages/theme`, so an upstream merge
usually conflicts only there. When Huly renames or adds a CSS variable, compare
upstream's `_colors.scss` and `_lumia-colors.scss` against the fork's and port the
new names over; anything missed simply falls back to Huly's default color.
