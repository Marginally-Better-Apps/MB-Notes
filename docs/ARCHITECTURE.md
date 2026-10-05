# Architecture

MB Notes is built like a game engine with mods. The **engine** knows how to store, draw, import, and export notes. Everything you *see* on a page (papers, covers, stickers, colors, folder icons) is **content** from packs, and the built-in content is just another pack.

```
┌────────────────────────── MBNotes (app) ───────────────────────────┐
│ Library UI · Editor · Recording · Settings · Liquid Glass theme    │
├──────────────── NoteIntelligence ────────────┬──── NoteEngine ─────┤
│ ModelManager (download/delete)               │ Format (Codable)    │
│ ShapeSnapping (Desert Ant Shapes)            │ PackRegistry        │
│ LiveRecorder (Apple SpeechAnalyzer)          │ TemplateRenderer    │
│ RecordingProcessor (Voz, FluidAudio, Uhm,    │ PageRenderer        │
│   Clear)                                     │ PDFExporter         │
│ TextInsights (Gist, Title)                   │ DocumentImporter    │
│ AIService (Apple, MLX, OpenAI-compatible)    │ HandwritingRecognizer│
└──────────────────────────────────────────────┴─────────────────────┘
         content: MBNotes/Resources/Packs/core.mbpack + Documents/Packs/*
```

## Packages

### `Packages/NoteEngine`

No UI. Depends only on Apple frameworks and ZIPFoundation.

- `Format/`: the `.mbnote` document model (`NoteManifest`, `PageSpec`, `PageElement`, `Transcript`, `FolderMetadata`). See [FORMAT.md](FORMAT.md).
- `Packs/`: the pack format and `PackRegistry`, which loads, validates, installs, and zips packs. `PackCatalog` is an immutable snapshot used to resolve `pack-id/item-id` references.
- `Rendering/`: `TemplateRenderer` turns layers into Core Graphics drawing, using one code path for the screen, thumbnails, and PDF export. `SVGPath` parses SVG path data. `PageRenderer` composes paper, imported page, elements, and ink.
- `Document/`: `LibraryStore` (folders on disk, plus trash), `NotePackage` (files inside a note), and `NoteFactory` (new notebooks and notes from pack content).
- `Import/`: converts everything to PDF first. PDF is used as is; Office and iWork files go through WebKit; OpenDocument goes ODF → HTML → WebKit; images and text are typeset.
- `Export/`: `PDFExporter` writes vector paper and text, raster ink, and an invisible recognized-text layer.
- `Recognition/`: Vision handwriting recognition per page.

Most of the engine also builds on macOS, so `swift test` runs quickly there.

### `Packages/NoteIntelligence`

On-device models and AI providers. See [MODELS.md](MODELS.md).

### `MBNotes` (the app)

- `Library/`: `NavigationSplitView` with a folder tree in the sidebar, gallery and list layouts, pinning, multi-select, one-tap notes, the notebook flow with live cover previews, the document scanner, Recently Deleted (30 days, restores to the original folder), and search across titles, handwriting, typed text, imported documents, and transcripts, grouped by note.
- `Editor/`: `EditorModel` owns the open note. `NoteCanvasController` is a single zoomable `PKCanvasView` spanning all pages. Page backgrounds are `CATiledLayer` views in an underlay scaled with the zoom, so they stay sharp. Elements live above the backgrounds and below the ink.
- `Recording/`: `RecordingController` handles live recording and transcription, post-processing, playback with filler skipping, and ink replay.
- `Settings/`: appearance (12 themes with light and dark palettes, System/Light/Dark, icon matching), writing and gesture options, AI, on-device models with download phases and enable switches, packs with install previews, and About.
- `App/`: `AppModel` is shared by every window (library, packs). `SceneModel` is per window (the open note, alerts, imports), so iPad windows show different notes.
- `Shared/Theme.swift`: `AppTheme` defines the palettes and is injected through the environment; `.tint` and `preferredColorScheme` follow it. Keep its cases in sync with `Scripts/render_icon.py` and `project.yml`.

## The canvas

- **One canvas, many pages.** Pages are stacked in document coordinates. Ink is stored per page in page coordinates; the controller stitches the pages into one `PKDrawing` and splits it back by each stroke's vertical center when saving.
- **Pencil first.** By default the Pencil draws and fingers scroll. Finger drawing is a toolbar toggle, on by default where `UIPencilInteraction.prefersPencilOnlyDrawing` is false. Text is a separate tool.
- **Shapes.** `ShapeSnapping` wraps Desert Ant's PencilKit integration, which forwards the canvas delegate, so ink-change callbacks still arrive.
- **Ink replay.** Every `PKStroke` stores its creation date. During playback, strokes written after the current audio time fade, and tapping a stroke jumps the audio to when you wrote it.

## Saving

Edits mark the note dirty, and a save runs after 1.2 seconds of quiet, when the app goes to the background, and when the note closes. Saves write `document.json` atomically, rewrite only the ink files that changed, and refresh the template snapshots in `embedded`. Handwriting recognition runs 3 seconds after a page's ink stops changing.

## Building

```sh
xcodegen generate
open MBNotes.xcodeproj
```

Or use [Gala Engine](https://github.com/Shlok-Bhakta/Gala-Engine) with the recipes at the repository root:

```sh
gala test     # ios-test.sh: engine and app tests on an iPad simulator
gala build    # ios-build.sh: unsigned Release IPA
gala deliver  # tests, build, sign, and private install link
```
