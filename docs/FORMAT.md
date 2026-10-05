# File format

MB Notes keeps your library as ordinary folders and files, so backing up is just copying a folder, and other tools can read your notes without MB Notes.

## Library

The library lives in the app's Documents folder, which the Files app shows as **On My iPhone/iPad › MB Notes › Library**.

```
Library/
  School/                      a folder: any directory
    .folder.json               its color, symbol, and stickers (optional)
    Biology.mbnote/            a note: a directory ending in .mbnote
    Chemistry/                 folders nest
  .Trash/                      Recently Deleted
Packs/                         installed community packs
```

- Copy `Library` to back up everything. Copy it back, or drop `.mbnote` folders into it, to restore.
- Files shows each `.mbnote` as a single document so it can be shared, but it is still a folder underneath.

### .folder.json

```json
{
  "format": "mbnotes.folder/1",
  "id": "8E6B1C4E-…",
  "color": "#8056F6",
  "symbol": "graduationcap.fill",
  "stickers": [{ "id": "…", "sticker": "com.marginallybetter.core/emoji-star", "x": 0.82, "y": 0.3, "scale": 0.9, "rotation": 0.2 }],
  "createdAt": "2026-10-03T20:41:00.000Z"
}
```

Sticker positions are fractions of the folder's width and height. Rotation is in radians.

## Notes (`.mbnote`)

```
Biology.mbnote/
  document.json                metadata, pages, elements, recordings
  ink/<page-id>.drawing        PencilKit drawing per page, in page coordinates
  recognition/<page-id>.json   handwriting recognized on that page
  media/<uuid>.png             inserted images
  sources/<uuid>.pdf           imported documents that pages draw on
  recordings/<id>.caf          audio (AAC, mono, in a crash-tolerant CAF container; older notes use .m4a)
  recordings/<id>.clear.m4a    optional cleaned-up audio
  recordings/<id>.json         transcript, speakers, filler words
  thumbnail.png                first page or cover, for previews
```

### document.json

```json
{
  "format": "mbnotes.note/1",
  "id": "…",
  "title": "Biology",
  "kind": "notebook",
  "createdAt": "…", "modifiedAt": "…",
  "accentColor": "#F76CA0",
  "cover": { "design": "com.marginallybetter.core/classic", "subtitle": "Fall", "stickers": [] },
  "defaultPaper": { "template": "com.marginallybetter.core/lined", "parameters": {} },
  "pages": [
    {
      "id": "…",
      "size": { "width": 612, "height": 792 },
      "paper": { "template": "com.marginallybetter.core/lined", "parameters": { "spacing": 24 }, "background": null },
      "source": { "file": "sources/….pdf", "pageIndex": 0 },
      "elements": [
        { "id": "…", "kind": "text", "frame": { "x": 72, "y": 72, "width": 300, "height": 40 }, "rotation": 0,
          "text": { "string": "Hello", "fontSize": 17, "color": "#1C1B2E", "alignment": "left" } },
        { "id": "…", "kind": "sticker", "frame": { … }, "rotation": 0.1, "sticker": "com.marginallybetter.core/emoji-star" },
        { "id": "…", "kind": "image", "frame": { … }, "rotation": 0, "image": "media/….png" }
      ],
      "createdAt": "…"
    }
  ],
  "tags": ["Biology & Life Sciences"],
  "recordings": [{ "id": "…", "title": "Lecture 3", "startedAt": "…", "duration": 3012.4,
                   "audioFile": "recordings/<id>.caf", "inProgress": false,
                   "pauses": [{ "start": 600.0, "end": 660.0 }] }],
  "embedded": { "papers": { "<ref>": { … } }, "covers": { … }, "stickers": { … } },
  "extensions": {}
}
```

- **Coordinates** are in points (1/72 inch) with a top-left origin. A US Letter page is 612 × 792.
- **`kind`** is `notebook` (has a cover and usually a title page), `note`, or `document` (imported).
- **Content references** look like `pack-id/item-id`.
- **`embedded`** stores a copy of every paper, cover, and sticker definition the note uses. A shared note renders correctly even where the pack isn't installed.
- **`extensions`** is reserved for tools and future features. Readers must preserve keys they don't understand.
- **`source`** draws a page of an imported PDF under the paper's ink. Imported PowerPoint, Word, Keynote, and OpenDocument files are converted to PDF on import.

### Ink

Each page's ink is a PencilKit `PKDrawing` (`dataRepresentation()`), in page coordinates. Every stroke records when it was written, which is how playback syncs ink to recordings.

PencilKit's format is Apple's own. For other platforms, `recognition/*.json` carries the text, and PDF export carries the visual ink. An open, cross-platform stroke format is on the roadmap.

### recognition/<page-id>.json

```json
{ "version": 1, "inkFingerprint": "a1b2…", "recognizedAt": "…",
  "lines": [{ "text": "mitochondria", "confidence": 0.92, "box": { "x": 96, "y": 180, "width": 210, "height": 28 } }] }
```

Exported PDFs draw these lines as invisible text over the ink, so the PDFs are searchable and selectable.

### recordings/<id>.json

```json
{
  "version": 1, "recordingID": "…", "startedAt": "…", "duration": 3012.4,
  "locale": "en_US", "engine": "desertant.voz",
  "segments": [{ "id": "…", "start": 12.3, "end": 18.9, "text": "Today we'll cover…", "speaker": "S1",
                 "words": [{ "text": "Today", "start": 12.3, "end": 12.6 }] }],
  "speakers": [{ "id": "S1", "name": "Professor", "color": "#4C3AD6" }],
  "hiddenSpeakers": ["S2"],
  "fillers": [{ "start": 40.1, "end": 40.5 }],
  "summary": null,
  "isProcessed": true
}
```

Hidden speakers are left out of the transcript view, search, and AI features.

Recordings are listed in `document.json` from the moment they start, with `inProgress: true`, and the audio is written as it is captured. If the app is killed mid-lecture, the next open finds the in-progress entry, reads the duration from the file, and keeps it. `pauses` are wall-clock stretches (seconds after `startedAt`) when recording was paused; ink replay uses them to line up strokes with the audio. `audioFile` is absent in notes made before CAF audio, which means `recordings/<id>.m4a`.

### Sharing

A `.mbnote` is a folder, which AirDrop and Files handle but Mail and Messages cannot attach. Sharing as a file zips the folder into a `.mbnotes` archive (`com.marginallybetter.notes.archive`, conforming to `public.zip-archive`) with the `.mbnote` folder at its top level. Audio is stored uncompressed inside the zip. Opening a `.mbnotes` file unzips it into the library as a new note with a fresh `id`.

## Packs

See [PACKS.md](PACKS.md).

## Versioning

Every JSON file has a `format` or `version` field. Readers ignore unknown fields and fill in defaults for missing ones. A breaking change would bump the number (`mbnotes.note/2`) and ship with a migration.
