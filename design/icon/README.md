# LoopKit icon source

Direction A was selected after comparing four generated logo explorations at 1024, 128, 32, and 16 pixels. Its single asymmetric routed cable stays legible at menu-bar size and avoids the standard infinity-symbol silhouette.

The shipping artwork is reconstructed as editable SVG layers:

- `layers/background.svg` — obsidian enclosure.
- `layers/loop.svg` — cable underlay and cyan/teal route.
- `layers/ports.svg` — the two endpoint ports.
- `layers/highlight.svg` — restrained cable highlight.
- `LoopKitIcon.svg` — flattened 1024-point master composition.
- `LoopKitMenuTemplate.svg` — monochrome menu-bar source.

Run `scripts/generate_icon_assets.sh` on macOS to deterministically rebuild the conventional asset catalog from these vector sources. Apple Icon Composer can import the layer SVGs when it is available; the checked-in asset catalog remains the portable fallback.
