# SakuraCord brand assets

This directory is the repository-owned library of SakuraCord marketing and
communication assets.

## Canonical icon sources

The editable Icon Composer projects remain beside the packaging system that
consumes them:

- `App/Packaging/SakuraCord.icon` — primary app icon.
- `App/Packaging/SakuraCord Nightly.icon` — violet nightly-build app icon.
- `App/Packaging/SakuraCord Debug.icon` — blueprint debug-build app icon.
- `App/Packaging/SakuraCord Flower.icon` — flower-only alternate app icon.
- `App/Packaging/SakuraCord Contributor.icon` — twin-bud contributor profile
  badge. It is not compiled into the app; its exports live in `Brand/Logos`.

`script/build_and_run.sh` compiles the variant matching the build: debug
builds are packaged as `SakuraCord Debug`, nightly-track release builds as
`SakuraCord Nightly`, and regular release builds as `SakuraCord`.

Do not edit a downsized PNG as the source of truth. Update the appropriate
`.icon` project, export a new 1024 px master, and regenerate the smaller sizes.

## Exported assets

- `Logos/SakuraCord` — full SakuraCord mark, with an opaque gradient background
  or transparent Liquid Glass treatment.
- `Logos/SakuraCord-Flower` — flower mark, with an opaque gradient background or
  transparent Liquid Glass treatment.
- `Icons` — Apple-rendered app icons and gradient-backed circle, rounded-square,
  and rounded-rectangle variants of both marks.
- `Banners` — text-free SakuraCord gradient banners in common platform and
  generic dimensions.
- `Sponsors` — sponsor avatars for the project README, with embedded images
  clipped to circles for GitHub-compatible rendering.
- `brand.json` — machine-readable brand name and gradient colors.

Exported PNGs are committed as individual files rather than ZIP archives so Git
can inventory each usable asset directly.
