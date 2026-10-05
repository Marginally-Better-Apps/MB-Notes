import NoteEngine
import Observation
import SwiftUI

/// State for one window: which note is open, alerts, and import progress.
/// On iPad each window gets its own, so two windows can show different notes.
@MainActor
@Observable
final class SceneModel {
    let app: AppModel
    var openNote: OpenNote?
    var alert: AppAlert?
    var importProgress: ImportProgress?
    /// A pack waiting for the user to confirm installation.
    var pendingPack: PackInstaller.Preview?

    struct OpenNote: Identifiable {
        let package: NotePackage
        /// Optional page to show first, for search results.
        var pageID: UUID?
        var id: URL { package.url }
    }

    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct ImportProgress {
        var completed = 0
        var total = 0
    }

    init(app: AppModel) {
        self.app = app
        #if DEBUG
        // Screenshot and test hook: `-openFirstNote` opens the newest note on launch.
        if ProcessInfo.processInfo.arguments.contains("-openFirstNote"), let first = app.library.allNotes().first {
            openNote = OpenNote(package: NotePackage(url: first.url))
        }
        #endif
    }

    func open(_ url: URL, pageID: UUID? = nil) {
        openNote = OpenNote(package: NotePackage(url: url), pageID: pageID)
    }

    func show(_ error: Error, title: String = "Something went wrong") {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    func show(title: String, message: String) {
        alert = AppAlert(title: title, message: message)
    }

    // MARK: Importing

    /// Imports files one by one, then reports all failures in one alert and opens a
    /// single imported note.
    func importFiles(_ urls: [URL], into folder: URL) async {
        importProgress = ImportProgress(completed: 0, total: urls.count)
        defer { importProgress = nil }
        var failures: [String] = []
        var imported: [NotePackage] = []
        var installed: [LoadedPack] = []
        for url in urls {
            if PackInstaller.looksLikePack(url) {
                // Packs get a preview and a confirmation instead of a silent install.
                await stagePack(url)
                importProgress?.completed += 1
                continue
            }
            do {
                switch try await app.importFile(url, into: folder) {
                case .note(let package): imported.append(package)
                case .pack(let pack): installed.append(pack)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            importProgress?.completed += 1
        }
        if !failures.isEmpty {
            let title = failures.count == 1 ? "Couldn't import a file" : "\(failures.count) of \(urls.count) files couldn't be imported"
            alert = AppAlert(title: title, message: failures.joined(separator: "\n"))
        } else if imported.count == 1, let only = imported.first {
            openNote = OpenNote(package: only)
        }
    }

    func stagePack(_ url: URL) async {
        do {
            pendingPack = try await PackInstaller.stage(url, registry: app.packs)
        } catch {
            show(error, title: "Couldn't read that pack")
        }
    }

    /// Handles files and links opened from other apps.
    func handleOpenURL(_ url: URL) {
        if url.scheme == "mbnotes" {
            handleScheme(url)
            return
        }
        if url.pathExtension.lowercased() == NotePackage.fileExtension, app.isInLibrary(url) {
            // Tapping a note in the Files app opens it; it does not make a copy.
            open(url)
            return
        }
        Task { await importFiles([url], into: app.library.root) }
    }

    /// `mbnotes://install?url=https://…` fetches a pack and previews it.
    private func handleScheme(_ url: URL) {
        guard url.host == "install",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remote = URL(string: raw), remote.scheme == "https" else { return }
        Task {
            do {
                let local = try await PackInstaller.fetch(remote)
                await stagePack(local)
            } catch {
                show(error, title: "Couldn't download that pack")
            }
        }
    }
}
