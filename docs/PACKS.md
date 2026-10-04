# Making packs

MB Notes is a note engine plus content. Every paper, notebook cover, sticker, color palette, and folder icon in the app comes from a **pack**, including the built-in ones. The built-in pack, [`MBNotes/Resources/Packs/core.mbpack`](../MBNotes/Resources/Packs/core.mbpack), uses exactly the format described here, so it is the best example to copy from.

Packs are data, not code. They hold JSON and images, so installing one is safe.

## Quick start

1. Copy [`examples/packs/cozy-cafe.mbpack`](../examples/packs/cozy-cafe.mbpack) and rename the folder.
2. Change `id` in `pack.json` to something unique, using reverse-DNS such as `io.github.yourname.cozy`.
3. Edit or add papers, covers, and stickers.
4. Zip the folder and rename the archive to end in `.mbpack`.
5. AirDrop the archive to your iPad, or open it from Files or Safari. MB Notes installs it. You can also use **Packs › +** inside the app.

To share a pack, open **Packs**, swipe left on it, and choose **Share**.

## Layout

```
my-pack.mbpack/
  pack.json          the manifest (required)
  papers/*.json      optional; items can also sit inline in pack.json
  covers.json
  stickers/*.json
  images/…           PNG, JPEG, or PDF assets referenced by layers
```

## pack.json

```json
{
  "format": "mbnotes.pack/1",
  "id": "io.github.yourname.cozy",
  "name": "Cozy Café",
  "version": "1.0.0",
  "author": "Your Name",
  "description": "Warm papers and coffee stickers.",
  "license": "CC-BY-4.0",
  "homepage": "https://github.com/yourname/cozy-pack",
  "minimumEngineVersion": "1.0",
  "papers": ["papers/cafe.json"],
  "covers": ["covers.json"],
  "stickers": ["stickers.json"],
  "palettes": [{ "id": "latte", "name": "Latte", "colors": ["#6F4E37", "#C8A27A", "#F3E5D0"] }],
  "symbolSets": [{ "id": "cafe", "name": "Café", "symbols": ["cup.and.saucer.fill", "birthday.cake.fill"] }]
}
```

Each list can contain inline objects, paths to JSON files, or both. A path can point to a file that holds one item or an array of items. Paths are relative to the pack and cannot leave it.

`id` must be unique. If you install a pack with the same `id` as one you already have, it replaces the older version. The built-in id `com.marginallybetter.core` is reserved.

## Papers

A paper is a background color plus a list of drawing **layers**, drawn in order with a top-left origin. Sizes are in points; 72 points is one inch.

```json
{
  "id": "cafe-lined",
  "name": "Café Lined",
  "category": "Lined",
  "role": "page",
  "background": "#FFF8EE",
  "parameters": {
    "spacing": { "label": "Line spacing", "default": 24, "min": 16, "max": 40, "step": 1 }
  },
  "layers": [
    { "type": "hlines", "spacing": "$spacing", "top": "$spacing * 3", "color": "#D9C3A5", "lineWidth": 0.7 },
    { "type": "line", "x1": 70, "y1": 0, "x2": 70, "y2": "100%", "color": "accent", "lineWidth": 1 }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `id`, `name` | Unique within the pack; shown in pickers. |
| `category` | Groups papers in the picker, for example `Lined`, `Grid`, `Planning`, or anything you like. |
| `role` | `page` (default), or `title` for a decorated first page offered when someone creates a notebook. |
| `size` | Optional `{ "width": 612, "height": 792 }`. Without it, the paper follows the user's page size. |
| `background` | A color (see below). |
| `parameters` | Sliders people can adjust per page. Layers use them as `$name`. |
| `layers` | The drawing. |

Notes save a snapshot of every template they use, so a note you share still looks right on a device that doesn't have your pack. Image assets are the exception: they need the pack installed.

### Lengths

A length is a number of points or a small expression:

- `72`: points
- `"50%"`: half of the page's width (for x and width) or height (for y and height)
- `"100% - 36"`: 36 points from the far edge
- `"$spacing * 2"`: a parameter
- Operators `+ - * /` and parentheses work.

### Colors

- Hex: `#RGB`, `#RRGGBB`, `#RRGGBBAA`
- Tokens: `accent` (the notebook's color), `accentLight`, `accentDark`, `paper`, `ink`, `white`, `black`, `clear`
- Opacity suffix: `accent@0.25`, `#000000@0.1`

Using `accent` makes your design follow whatever color someone picks for their notebook.

### Layer types

Every layer accepts `opacity`, `rotation` (degrees, around its box), and `repeat`:

```json
{ "type": "rect", "x": 44, "y": 76, "width": 16, "height": 16, "stroke": "accent", "repeat": { "count": 30, "dy": 32 } }
```

| type | Draws | Fields |
| --- | --- | --- |
| `fill` | Solid color | `color`; optional `x y width height` |
| `gradient` | Linear gradient | `colors` (2+), `angle` in degrees; optional box |
| `hlines` | Horizontal rules | `spacing`, `top`, `bottom`, `left`, `right`, `color`, `lineWidth`, `dash` |
| `vlines` | Vertical rules | same as `hlines` |
| `grid` | Square grid | `spacing`, insets, `color`, `lineWidth`, `majorEvery`, `majorColor`, `majorWidth` |
| `dots` | Dot grid | `spacing`, `radius`, insets, `color` |
| `isometric` | Triangle grid | `spacing`, `style` (`lines` or `dots`), `radius` |
| `staff` | Music staves | `spacing` (gap between the 5 lines), `staffGap`, insets |
| `rect` | Rectangle | `x y width height`, `fill`, `stroke`, `lineWidth`, `cornerRadius`, `dash` |
| `ellipse` | Ellipse | `x y width height`, `fill`, `stroke`, `lineWidth` |
| `line` | Segment | `x1 y1 x2 y2`, `color`, `lineWidth`, `dash` |
| `path` | SVG path data | `d`, `viewBox` `[x, y, w, h]`, box, `fill`, `stroke`, `lineWidth` |
| `text` | Text | `text`, box, `fontSize`, `weight`, `design`, `align`, `color`, `style: "middle"` to center vertically |
| `symbol` | SF Symbol | `symbol`, box, `color` |
| `image` | PNG or JPEG | `src`, box, `style: "fill"` to crop instead of fit |
| `pdf` | A PDF page | `src`, `page` (0-based), box |

- Pattern layers (`hlines`, `dots`, and similar) fill the page minus the `top bottom left right` insets.
- `path` accepts every SVG path command, including arcs, and scales the path to fit its box. That makes it easy to paste icons from vector editors.
- `text` supports placeholders: `{{title}}`, `{{subtitle}}`, `{{date}}`, `{{year}}`, `{{page}}`.
- `weight` is one of `light`, `regular`, `medium`, `semibold`, `bold`, `heavy`.
- `design` is one of `default`, `rounded`, `serif`, `monospaced`, `handwritten`.

Unknown layer types are skipped, so a pack written for a newer version of MB Notes still opens in an older one.

## Covers

Covers use the same layers on a 300 × 400 canvas. `background` defaults to `accent`. `defaultColor` sets the notebook color when someone picks the cover.

```json
{
  "id": "cafe", "name": "Café", "defaultColor": "#6F4E37",
  "layers": [
    { "type": "dots", "spacing": 24, "radius": 3, "color": "white@0.2" },
    { "type": "rect", "x": 50, "y": 120, "width": 200, "height": 96, "cornerRadius": 14, "fill": "white@0.94" },
    { "type": "text", "text": "{{title}}", "x": 60, "y": 124, "width": 180, "height": 70, "fontSize": 22, "weight": "bold", "align": "center", "color": "accentDark", "style": "middle" }
  ]
}
```

## Stickers

A sticker uses exactly one kind of art:

```json
[
  { "id": "latte", "name": "Latte", "category": "Café", "emoji": "☕️" },
  { "id": "bean", "name": "Bean", "category": "Café", "symbol": "leaf.fill", "tint": "#6F4E37" },
  { "id": "croissant", "name": "Croissant", "category": "Café", "image": "images/croissant.png" },
  { "id": "badge", "name": "Open", "category": "Café", "canvas": { "width": 160, "height": 70 },
    "layers": [ { "type": "rect", "x": 4, "y": 4, "width": 152, "height": 62, "cornerRadius": 31, "fill": "#6F4E37" },
                { "type": "text", "text": "OPEN", "x": 4, "y": 4, "width": 152, "height": 62, "fontSize": 26, "weight": "heavy", "align": "center", "color": "white", "style": "middle" } ] }
]
```

Symbol stickers get a white die-cut border unless you set `"outlined": false`. For image stickers, use transparent PNGs, about 512 pixels on the long side.

## Testing your pack

- Install the pack and open **Packs**. If anything fails to load, the error appears under **Couldn't load**, naming the file and the JSON path that's wrong.
- From the repository, `swift test` in `Packages/NoteEngine` validates the core pack. To render every paper and cover of the core pack to PNGs, set `MBNOTES_PREVIEW_DIR=/tmp/previews`.

## Licensing

Say how others may use your pack in `license`. CC0 or CC BY works well for art. The core pack is CC0.
