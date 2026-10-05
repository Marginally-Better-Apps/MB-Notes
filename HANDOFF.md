# Handoff: UX overhaul (October 2026)

This covers the `ux-overhaul` branch: what changed, what was checked, what wasn't, and what to do next. It was written for whoever picks the work up next, human or agent.

## How this was done

Six read-only audits ran first, one per area: editor, recording, on-device models, visual design and theming, stickers and licensing, and library and app-wide UX. Their findings drove every change here. All implementation then happened in one pass by one agent, to avoid merge problems between parallel workers.

## Status

- **Builds:** the app builds for the iOS simulator with one warning (see Known issues).
- **Tests:** all pass. That's 41 NoteEngine tests (`swift test` in `Packages/NoteEngine`) plus the app's test target via the full `test` action.
- **Checked visually:** on the iPad Pro 13" and iPhone 17 Pro simulators, from screenshots: the library, the editor (light and dark), Settings, and the theme picker.
- **Not checked interactively:** the simulator couldn't be driven (tapping and drawing) from this environment. Every gesture, tap flow, and sheet below was built and compiles, but **none has been exercised by hand**. Treat the first device session as the real test. The checklist is at the end.

## What changed

### Recording (the dead record button)

- **Root cause:** `NotePackage.fileURL` compared standardized paths. On a real device the app container sits under `/private/var` (a symlink to `/var`), and `standardizedFileURL` only strips `/private` from paths that already exist. So the new audio file's path was rejected, and `RecordingController.start()` returned silently before ever asking for the microphone. The simulator doesn't use `/var`, so tests never caught it.
  - **Fix:** check path components instead.
  - **Test:** `newFilesResolveInsideNotesFoundByListing` reproduces the device layout on macOS and fails on the old code.
- **Background audio:** `UIBackgroundModes` and `UIFileSharingEnabled` were set as `INFOPLIST_KEY_*` build settings, which Xcode silently ignores. They now live in `Info.plist`.
- **New recording states:**
  - `.starting` disables the button, so mashing it no longer starts many recordings.
  - `.paused` adds pause and resume.
  - Recording begins right away, and the live transcript joins in once Apple's speech model has downloaded.
- **Interruptions:** phone calls and Siri pause the recording, connecting AirPods re-taps the input, and the timers keep running while you scroll.
- **Crash safety:** audio is written as AAC in a `.caf` file. The recording is listed in `document.json` with `inProgress: true` from the first second, and it's recovered on the next open if the app died. Older `.m4a` notes still play.
- **UI:** the recording bar has a pulsing dot, `h:mm:ss`, a scrolling waveform, and pause and stop. Playback scrolls the transcript and highlights the word being spoken.
- **Sharing:** recordings were already stored inside the note. Notes can now also be shared as one `.mbnotes` zip, which Mail and Messages can attach, with a "without recordings" option. The format is documented in `docs/FORMAT.md` under Sharing.

### On-device models

- **Download progress:** downloads report phases: bytes received, speed, and time left; then "Optimizing for this device…" during the Core ML compile, which is what made the bar look stuck at 100%; then ready.
  - The Hugging Face downloader now gets real byte progress through a session delegate. The async API it used before never reports progress.
  - It verifies LFS SHA-256 checksums and writes a `.complete` marker last.
- **Safer deletion:** tapping a model card no longer deletes the model. A default-style `Button` inside a `List` row was capturing taps on the whole row. Delete is now a swipe or a menu item, and it asks for confirmation and shows how much space it frees.
- **On/off switches:** each model can be switched off and kept on disk. Features check `ModelManager.isUsable(_:)`, and Settings shows dependent toggles as unavailable while a model is off.
- **Cancelling:** cancelled downloads can no longer overwrite a newer download's state (they're tracked with a generation counter).

### Theming and look

- **12 themes:** Iris, Graphite, Ocean, Sage, Lagoon, Ember, Cherry, Rose, Honey, Plum, Indigo, and Sepia, each with light and dark palettes (`AppTheme` in `MBNotes/Shared/Theme.swift`). There's also a System/Light/Dark setting and a "Match App Icon to Theme" toggle. A test checks that every light accent meets WCAG AA contrast on white.
- **Gradients removed:** the animated mesh-gradient backdrop is gone from every screen, along with the gradient tool chip, the folder glow, and the gradient covers and papers in the core pack.
- **App icon:** one flat sheet of ruled paper with a single accent margin line, rendered by `Scripts/render_icon.py` in light, dark, and tinted variants for every theme. The old Midnight, Mint, Lemonade, Bubblegum, and Kraft icons were removed.
- **Folders:** drawn flat, like the Files app, with an item count under the name.
- **Native controls:** forms replaced the custom sheets, along with native toolbars, `.confirm` and `.cancel` button roles, a shared set of corner radii (`Radius`), haptics, hover effects, and composed VoiceOver labels.

### Editor

- **Pages:** side by side by default, with continuous scrolling available in Settings and per note from the title menu. `PageLayout` (in NoteEngine, with tests) owns all page geometry. Flicks snap to whole pages.
- **Undo:**
  - Each note now has its own undo history, covering ink, pages, elements, text, and paper. `NoteCanvas` returns the note's `UndoManager`, so PencilKit and the tool picker share that one history.
  - Deleting a page can be undone. Its files are only removed on save, once nothing can bring the page back.
- **Gestures:**
  - Tap with two fingers to undo and three to redo; hold either to repeat, speeding up. A banner names what was undone.
  - Double-tap with a finger to zoom between fit and 2×, and pinching near fit snaps to fit.
  - Apple Pencil double-tap and squeeze work, and iPadOS's own three-finger gestures are turned off.
  - Keyboard shortcuts: ⌘Z / ⇧⌘Z, ⌥⌘1–4 for modes, Delete, ⌘0, and ⌘W.
- **Toolbar:** built from system toolbars. The modes are View, Pen, Text, and Select. There's a Convert toggle and an Insert menu (photo, scan, sticker or emoji, text box, PDF, page before or after), and undo and redo are always visible.
  - **iPhone:** opens in View mode, so one finger scrolls. Pen swaps the bottom bar for the tool picker, and Done goes back.
  - **Convert mode:** write, pause for a second, and the strokes become a text box. Undo brings the ink back. "Convert Page to Text…" handles whole pages.
- **Pages view:** swipe to delete or duplicate. Long-press gives duplicate, insert before or after, move to start or end, and delete. Edit mode allows reordering, and thumbnails refresh when a page changes.
- **Text:** while typing, a strip above the keyboard has colors, size, alignment, and Done. A text box's long-press menu has a color palette. New text boxes reuse the last style. The canvas scrolls the caret above the keyboard.
- **Select mode:** tapping selects with handles. Bring to Front and Send to Back are now saved to the note, and paste and drag-and-drop of images and text work.
- **Shape snapping:** a new `StrokeBeautifier` in NoteEngine (plain geometry, with tests).
  - Hold the pen still at the end of a stroke and it becomes one of:
    - a line, snapped to 45° steps
    - an arrow, either from one stroke or a line followed by a quick caret
    - an elbow connector
    - a triangle, rectangle or square
    - a regular polygon or star
    - an ellipse or circle
  - Handwriting isn't touched because it's never held. The Desert Ant Shapes model is no longer used for snapping.

### Stickers, packs, and licensing

- **Removed:** anything not made for MB Notes:
  - 24 SF Symbol stickers
  - the `symbol` layer and sticker types
  - a star path copied from Material Icons, replaced by a generated `star` layer
  - an unsourced example croissant image, now drawn by `Scripts/render_example_assets.py`
- **License:** the core pack has a CC0 `LICENSE`, and a test asserts that core stickers are only emoji or vector layers.
- **Emoji stickers:** any emoji can be a sticker through the system emoji keyboard (`EmojiKeyboardField`). Only the character is stored, as a virtual `mbnotes.emoji` pack. The sticker picker gained search, recents, and "Get More Stickers".
- **Installing packs:** every way a pack arrives goes through `PackInstaller.stage`:
  - It runs off the main thread.
  - It enforces size and file-count limits, rejects symlinks, and validates ids.
  - It shows a preview sheet with the author, license, an update or different-author warning, and a responsibility notice before installing.
  - Packs can come from Files (including zips and folders), drag and drop, a link, or `mbnotes://install?url=https://…`.
- **Docs:** `docs/PACKS.md` has a new "Rights and responsibility" section.

### Library and app

- **Windows:** state is split into `AppModel` (shared by all windows) and `SceneModel` (one per window). iPad windows no longer share a single open note, and "Open in New Window" works.
- **Opening from Files:** opening a note that's already in the library opens it in place instead of making a copy.
- **Sidebar:** a folder tree with counts, drop targets, and New Folder. Settings moved to a sheet, and Packs moved into Settings.
- **Browsing:** gallery or list layout, with Notes-style date sections in the list, Pinned, and per-folder sort. Multi-select supports bulk move and delete. The context menu follows Apple's order and adds Pin, Open in New Window, Share (PDF or MB Notes file), and so on. Swipe actions work in the list.
- **New notes:**
  - One tap on the compose button creates a note with the last-used paper. Holding it offers New Notebook, New Folder, Scan Documents, and Import.
  - New notes are titled "Note Oct 4".
  - The notebook sheet is now a `Form` with a live cover preview.
- **Search:** results are grouped by note and include text from imported PDFs. They're cancellable, scoped to All Notes or This Folder, show the match highlighted, and open on the matching page.
- **Recently Deleted:** items restore to their original folder (from a `.Trash/.index.json` index), show days left, are purged after 30 days, and can be deleted individually. Emptying asks for confirmation.
- **Menu bar:** iPadOS menu-bar commands and keyboard shortcuts for New Note, Notebook, Folder, Import, Scan, View, and the Note menu.
- **Transitions:** a zoom transition from a library tile into the editor.

### Build speed

- **Fast build script:** `/Volumes/BlenderBuild/Projects/.mbnotes-build/build.sh [build|test]` (outside the repo). It:
  - builds for one concrete arm64 simulator, so packages aren't compiled twice for x86_64
  - keeps DerivedData in one stable place, with a shared package checkout
  - turns on Xcode's compilation cache, and skips package updates
- **Timing:** MLX, Desert Ant, and FluidAudio compile once (about 15 minutes cold). After that a build takes 3–4 minutes.
- **Gala:** `ios-build.sh` and `ios-test.sh` also turn on the compilation cache.
- **Machine limits:** the Mac has 8 GB of RAM, so run only one `xcodebuild` at a time.

## Known issues and loose ends

1. **One compiler warning:** `Theme.swift:111`, where a non-Sendable `completion` is passed to `setAlternateIconName`. It's harmless; mark the closure `@Sendable` to clear it.
2. **A debug hook in a release path:** `RootView` attaches `.navigationDestination(isPresented: .constant(UserDefaults…"showTheme"))` outside the `#if DEBUG` block. It's always false in normal use, but it belongs inside the `#if`.
3. **Undo across page rebuilds is still not fully reliable.** Page and element changes use snapshot undo, but PencilKit stroke undos registered before a layout rebuild (adding, deleting, or reordering pages) refer to the old single-canvas layout. Test: draw, add a page above, undo twice. The real fix is per-page canvases (see Next steps).
4. **Dead code:** `ShapeSnapping.setEnabled` is no longer called. Remove it, or keep the Desert Ant model only as an optional classifier behind `StrokeBeautifier`.
5. **No migration for old icons:** users whose alternate icon was one of the removed sets aren't moved to a new one. This doesn't matter before 1.0, since nothing has shipped.
6. **The welcome note is seeded once.** Simulators and devices that already ran an older build keep the old pink welcome notebook. A fresh install gets the new one.
7. **Text styling is per box,** not per word. Color, size, and alignment apply to the whole box.
8. **Emoji keyboard fallback:** if the user has removed the Emoji keyboard, or an iPad has a hardware keyboard attached, the system emoji keyboard won't appear. There's no grid fallback yet.

## Next steps, in priority order

1. **Test on a real device, especially recording.** The recording fix is a strong lead, reproduced on macOS, but it hasn't been confirmed on a device. Check:
   - [ ] Tap record: the microphone prompt appears, then the timer and waveform run. Pause, resume, and stop all work. The transcript appears.
   - [ ] Lock the screen mid-recording: audio keeps recording.
   - [ ] Force-quit mid-recording, then reopen the note: the recording is recovered.
   - [ ] Share as an MB Notes file through Messages, then open it on another device: the recording and ink replay come along.
   - [ ] Two-finger tap undoes, three-finger tap redoes, and holding repeats. With finger drawing on, there are no stray dots.
   - [ ] Side-by-side paging snaps, and rotating keeps the current page.
   - [ ] Hold-to-snap shapes: lines, arrows (one stroke, and line then caret), rectangles, circles, stars.
   - [ ] Convert mode turns writing into a text box, and undo restores the ink.
   - [ ] The pages view swipe and long-press actions work, and deleting a page can be undone.
   - [ ] Changing the theme shows the iOS icon alert once, and the icon changes.
   - [ ] Model downloads show their phases, and switching a model off disables its features.
   - [ ] The emoji keyboard opens from the sticker picker.
   - [ ] Installing a pack from a link shows the preview sheet.
2. **Per-page canvases** (the editor audit's "Phase 2"): one `PKCanvasView` per visible page, virtualized. This fixes undo across page rebuilds and keeps 150-page PDFs fast.
3. **A rich-text note type** with checklists and tables. This is the biggest gap against Apple Notes. It needs a TextKit 2 note type, so it's a format change: put it in NoteEngine with tests, and document it in `docs/FORMAT.md`.
4. **Per-word text styling:** add `TextContent.runs` (decoded only if present, so older notes still open), with support in the renderer and PDF export.
5. **An emoji grid fallback** generated from Unicode properties at runtime, for devices where the system emoji keyboard isn't available.
6. **A background search index** plus Spotlight (`CSSearchableIndex`), and Handoff with `@SceneStorage` for the open note.
7. **Lock** (Face ID), a Tags screen, a Quick Look thumbnail extension for `.mbnote`, widgets, and App Intents.
8. **iCloud sync.**

## Pointers

- **Audits:** the six full reports are in `/Volumes/BlenderBuild/Projects/.mbnotes-build/audits/` (outside the repo). Each finding cites `file:line` from before this branch.
- **Debug launch arguments:**

  | Argument | What it does |
  | --- | --- |
  | `-openFirstNote` | Opens the newest note on launch |
  | `-scrollToLastPage` | Jumps to the last page after opening |
  | `-showSettings 1` | Opens Settings on launch |
  | `-showTheme 1` | Opens the theme picker on launch |
  | `-theme ocean` | Sets the theme for the launch (any `AppTheme` raw value) |

  Example: `xcrun simctl launch <udid> com.marginallybetter.notes -openFirstNote`.
- **Docs:**
  - `docs/FORMAT.md`: recordings fields and sharing archives
  - `docs/PACKS.md`: the `star` layer, sticker `tags`, emoji, and rights
  - `docs/MODELS.md`: download phases and shape snapping
  - `docs/ARCHITECTURE.md`: app and scene state, and themes
  - `CLAUDE.md`: design and content rules, and the fast build
