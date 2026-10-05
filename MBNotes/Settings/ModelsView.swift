import NoteIntelligence
import SwiftUI

/// Download, switch on and off, and delete on-device models.
struct ModelsView: View {
    @State private var manager = ModelManager.shared
    @State private var customRepo = ""
    @State private var pendingDelete: OnDeviceModel?

    var body: some View {
        List {
            Section {
                ForEach(OnDeviceModel.allCases.filter { $0 != .localLLM }) { model in
                    ModelRow(model: model, manager: manager, requestDelete: { pendingDelete = model })
                }
            } header: {
                Text("Note and Recording Models")
            } footer: {
                Text("Small models download by themselves the first time a feature needs them. Larger ones wait for you. Everything runs on this device. Swipe left on a model to delete it; switch it off to keep it without using it.")
            }

            Section {
                ForEach(LocalModelPreset.all) { preset in
                    Button {
                        manager.localModelID = preset.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                Text("\(preset.size) · \(preset.note)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .opacity(manager.localModelID == preset.id ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(manager.localModelID == preset.id ? .isSelected : [])
                }
                HStack {
                    TextField("Any MLX model, e.g. mlx-community/…", text: $customRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use") { manager.localModelID = customRepo.trimmingCharacters(in: .whitespaces) }
                        .buttonStyle(.borderless)
                        .disabled(!customRepo.contains("/"))
                }
                ModelRow(model: .localLLM, manager: manager, requestDelete: { pendingDelete = .localLLM })
            } header: {
                Text("Local Language Model")
            } footer: {
                Text("Pick a small Hugging Face model for summaries and questions without the internet. Then choose “On-device model” in Settings › AI.")
            }

            Section {
                LabeledContent("Model Storage", value: ByteCountFormatter.string(fromByteCount: totalStorage, countStyle: .file))
            }
        }
        .navigationTitle("On-Device Models")
        .onAppear { manager.refresh() }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Model", role: .destructive) {
                if let model = pendingDelete { manager.delete(model) }
                pendingDelete = nil
            }
        } message: {
            if let model = pendingDelete {
                Text("Frees \(ByteCountFormatter.string(fromByteCount: manager.diskUsage(model), countStyle: .file)). \(model.purpose) You can download it again any time.")
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.map { "Delete \($0.name)?" } ?? ""
    }

    private var totalStorage: Int64 {
        OnDeviceModel.allCases.reduce(0) { $0 + manager.diskUsage($1) }
    }
}

/// One model: what it does, where it is, and one control. The row itself is never a button,
/// so tapping it does nothing destructive.
private struct ModelRow: View {
    let model: OnDeviceModel
    let manager: ModelManager
    let requestDelete: () -> Void

    private var phase: ModelPhase { manager.phase(model) }
    private var enabled: Bool { manager.isEnabled(model) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.systemImage)
                .font(.title3)
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model == .localLLM ? manager.localModelID.components(separatedBy: "/").last ?? model.name : model.name)
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Text(model.vendor).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                status
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            if phase.isReady {
                Button(role: .destructive, action: requestDelete) { Label("Delete", systemImage: "trash") }
            }
        }
        .contextMenu {
            if phase.isReady {
                Toggle(isOn: Binding(get: { enabled }, set: { manager.setEnabled(model, $0) })) { Label("Enabled", systemImage: "power") }
                Button(role: .destructive, action: requestDelete) { Label("Delete Model", systemImage: "trash") }
            } else if phase == .notDownloaded {
                Button { manager.download(model) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .notDownloaded:
            Text(model.downloadsAutomatically ? "\(model.approximateSize) · Downloads when first needed" : "\(model.approximateSize) · Wi‑Fi recommended")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading(let received, let total, let rate):
            VStack(alignment: .leading, spacing: 3) {
                if let total {
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(downloadText(received: received, total: total, rate: rate)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .verifying:
            Label("Checking files…", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
        case .preparing(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Text(enabled ? "On this device · \(ByteCountFormatter.string(fromByteCount: manager.diskUsage(model), countStyle: .file))" : "Off · still on this device")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var control: some View {
        switch phase {
        case .notDownloaded:
            Button("Download") { manager.download(model) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .font(.subheadline.weight(.semibold))
        case .downloading:
            Button { manager.cancel(model) } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
        case .verifying, .preparing:
            EmptyView()
        case .ready:
            Toggle("Enabled", isOn: Binding(get: { enabled }, set: { manager.setEnabled(model, $0) }))
                .labelsHidden()
        case .failed:
            Button("Try Again") { manager.download(model) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        case .unavailable:
            EmptyView()
        }
    }

    private func downloadText(received: Int64, total: Int64?, rate: Double?) -> String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        var parts: [String] = []
        if let total {
            parts.append("\(got) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        } else {
            parts.append(got)
        }
        if let rate, rate > 1024 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s")
            if let total, total > received {
                let seconds = Double(total - received) / rate
                parts.append("about \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 1))) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityValue: String {
        switch phase {
        case .downloading(let received, let total, _):
            if let total { return "Downloading, \(Int(Double(received) / Double(max(total, 1)) * 100)) percent" }
            return "Downloading"
        case .preparing(let message): return message
        case .ready: return enabled ? "Ready" : "Off"
        case .failed(let message): return "Failed: \(message)"
        default: return ""
        }
    }
}
