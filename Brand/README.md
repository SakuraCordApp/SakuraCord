# MarrowChat brand assets

This directory is the repository-owned library of MarrowChat marketing and
communication assets.

## Canonical icon sources

The editable Icon Composer projects remain beside the packaging system that
consumes them:

- `App/Packaging/MarrowChat.icon` — primary app icon.
- `App/Packaging/MarrowChat Flower.icon` — flower-only alternate app icon.

Do not edit a downsized PNG as the source of truth. Update the appropriate
`.icon` project, export a new 1024 px master, and regenerate the smaller sizes.

## Exported assets

- `Logos/MarrowChat` — full MarrowChat mark, with an opaque gradient background
  or transparent Liquid Glass treatment.
- `Logos/MarrowChat-Flower` — flower mark, with an opaque gradient background or
  transparent Liquid Glass treatment.
- `Icons` — Apple-rendered app icons and gradient-backed circle, rounded-square,
  and rounded-rectangle variants of both marks.
- `Banners` — text-free MarrowChat gradient banners in common platform and
  generic dimensions.
- `brand.json` — machine-readable brand name and gradient colors.

All exported PNGs are intentionally committed uncompressed rather than wrapped
in ZIP archives so Git can inventory each usable asset directly.
