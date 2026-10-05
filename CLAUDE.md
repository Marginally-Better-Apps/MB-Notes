# MB Notes agent notes

- Generate the Xcode project with `xcodegen generate`; never commit `MBNotes.xcodeproj` edits by hand (it is generated, but checked in for convenience).
- Engine logic belongs in `Packages/NoteEngine` with tests (`swift test` there). Model and AI code belongs in `Packages/NoteIntelligence`.
- Built-in content is data in `MBNotes/Resources/Packs/core.mbpack`. Prefer adding layer types to the engine over hard-coding art in Swift; document new layer fields in `docs/PACKS.md`.
- Keep the brand palette from the app icon (peach #FFA678, pink #F76CA0, violet #8056F6, ink #4C3AD6, star #FFC428) and Liquid Glass surfaces.
- App icons come from `Scripts/render_icon.py`; keep its THEMES in sync with `AppTheme` in `MBNotes/Shared/Theme.swift` and the alternate icon list in `project.yml`. Icons are flat and wordless.
- Design direction: Apple-grade and restrained. No gradients, no decorative sparkle; system materials, native controls, and the theme's accent. UX first.
- Content rule: ship only art made for MB Notes. No SF Symbols or third-party assets as stickers or in packs; emoji are stored as characters.
- Gala: `gala test` / `gala build` / `gala deliver` use `ios-test.sh` and `ios-build.sh`.
- Fast local builds: `/Volumes/BlenderBuild/Projects/.mbnotes-build/build.sh [build|test]` builds one simulator arch into a stable DerivedData with the compilation cache, so dependencies compile once.
