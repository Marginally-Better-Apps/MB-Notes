import NoteEngine
import PencilKit
import SwiftUI

/// Page thumbnails: jump, reorder, duplicate, and delete.
struct PageNavigator: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [UUID: UIImage] = [:]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.manifest.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 16) {
                        Group {
                            if let image = thumbnails[page.id] {
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Rectangle().fill(.quaternary).aspectRatio(page.size.width / page.size.height, contentMode: .fit)
                            }
                        }
                        .frame(height: 110)
                        .clipShape(.rect(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.pink, lineWidth: index == model.currentPageIndex ? 3 : 0))
                        VStack(alignment: .leading) {
                            Text("Page \(index + 1)").font(.headline)
                            Text(model.catalog.resolvePaper(page.paper.template, embedded: model.manifest.embedded).name)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        model.canvas?.scroll(toPage: index)
                        dismiss()
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.deletePage(index) } label: { Label("Delete", systemImage: "trash") }
                            .disabled(model.pageCount <= 1)
                        Button { model.duplicatePage(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            .tint(Brand.violet)
                    }
                    .task(id: page.id) {
                        let renderer = model.renderer
                        let ink = model.drawing(for: page.id)
                        thumbnails[page.id] = await Task.detached { renderer.image(for: page, width: 180, ink: ink) }.value
                    }
                }
                .onMove { model.movePage(from: $0, to: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.addPage(after: model.pageCount - 1) } label: { Label("Add page", systemImage: "plus") }
                }
            }
        }
    }
}

/// Change the paper for this page or the whole note, and tune template parameters.
struct PaperSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ContentRef.blankPaper
    @State private var parameters: [String: Double] = [:]
    @State private var applyToAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let template = model.catalog.resolvePaper(selection, embedded: model.manifest.embedded)
                    if !template.parameters.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(template.parameters.keys.sorted(), id: \.self) { key in
                                let parameter = template.parameters[key]!
                                VStack(alignment: .leading) {
                                    Text("\(parameter.label): \(Int(parameters[key] ?? parameter.defaultValue))").font(.subheadline)
                                    Slider(value: Binding(get: { parameters[key] ?? parameter.defaultValue }, set: { parameters[key] = $0 }),
                                           in: (parameter.minimum ?? 0)...(parameter.maximum ?? 100), step: parameter.step ?? 1)
                                }
                            }
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
                    Toggle("Apply to every page", isOn: $applyToAll)
                    PaperGrid(selection: $selection, accent: model.manifest.accentColor, parameters: parameters)
                }
                .padding(20)
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.setPaper(PaperRef(template: selection, parameters: parameters), allPages: applyToAll)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .onAppear {
                let page = model.manifest.pages[safe: model.currentPageIndex]
                selection = page?.paper.template ?? model.manifest.defaultPaper.template
                parameters = page?.paper.parameters ?? [:]
            }
            .onChange(of: selection) { parameters = [:] }
        }
    }
}

/// Shows recognized handwriting for the current page so it can be copied or typed in.
struct ConvertHandwritingSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = true

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    ProgressView("Reading your handwriting…")
                } else if text.isEmpty {
                    ContentUnavailableView("No handwriting found", systemImage: "scribble", description: Text("Write on this page, then try again."))
                } else {
                    TextEditor(text: $text)
                        .padding()
                }
            }
            .navigationTitle("Handwriting to text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Use") {
                        Button("Copy") { UIPasteboard.general.string = text }
                        Button("Add as a text box") {
                            let index = model.currentPageIndex
                            if let page = model.manifest.pages[safe: index] {
                                model.addElement(.text(text, frame: Rect(x: 60, y: 60, width: page.size.width - 120, height: 200)), toPage: index)
                            }
                            dismiss()
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }
            .task {
                model.canvas?.flushInk()
                guard let page = model.manifest.pages[safe: model.currentPageIndex] else { return }
                await model.recognize(page.id)
                text = model.recognitionByPage[page.id]?.text ?? ""
                isWorking = false
            }
        }
    }
}
