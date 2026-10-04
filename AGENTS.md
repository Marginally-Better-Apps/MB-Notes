# MB Notes agent notes

- Generate the Xcode project with `xcodegen generate`; never commit `MBNotes.xcodeproj` edits by hand (it is generated, but checked in for convenience).
- Engine logic belongs in `Packages/NoteEngine` with tests (`swift test` there). Model and AI code belongs in `Packages/NoteIntelligence`.
- Built-in content is data in `MBNotes/Resources/Packs/core.mbpack`. Prefer adding layer types to the engine over hard-coding art in Swift; document new layer fields in `docs/PACKS.md`.
- Keep the brand palette from the app icon (peach #FFA678, pink #F76CA0, violet #8056F6, ink #4C3AD6, star #FFC428) and Liquid Glass surfaces.
- App icons come from `Scripts/render_icon.py`; keep its THEMES in sync with `AppIconTheme` and `project.yml`.
- Gala: `gala test` / `gala build` / `gala deliver` use `ios-test.sh` and `ios-build.sh`.
