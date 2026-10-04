import DesertAnt
import SwiftUI

@main
struct MBNotesApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Brand.pink)
                .onOpenURL { app.handleOpenURL($0) }
                .fullScreenCover(item: $app.openNote) { note in
                    EditorView(package: note.package)
                        .environment(app)
                        .tint(Brand.pink)
                }
                .alert(item: $app.alert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message))
                }
                .overlay {
                    if app.isImporting {
                        ProgressView("Importing…")
                            .padding(24)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
        }
    }
}
