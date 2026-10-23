import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var extractor = Extractor()

    private enum Target { case game, update, keys }

    @State private var gameURL: URL?
    @State private var updateURL: URL?
    @State private var keysURL: URL?
    @State private var pickerTarget: Target = .game
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Inputs") {
                    pickerRow(title: "Game (XCI / NSP)", url: gameURL, required: true) { open(.game) }
                    pickerRow(title: "Update NSP (optional)", url: updateURL, required: false) { open(.update) }
                    pickerRow(title: "prod.keys", url: keysURL, required: true) { open(.keys) }
                    if updateURL != nil {
                        Button("Remove update", role: .destructive) { updateURL = nil }
                    }
                }

                Section {
                    Button {
                        guard let g = gameURL, let k = keysURL else { return }
                        Task { await extractor.run(game: g, update: updateURL, keys: k) }
                    } label: {
                        HStack {
                            if extractor.isRunning { ProgressView().padding(.trailing, 6) }
                            Text(extractor.isRunning ? "Working…" : "Extract")
                        }
                    }
                    .disabled(gameURL == nil || keysURL == nil || extractor.isRunning)

                    Text(extractor.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !extractor.outputs.isEmpty {
                    Section("Results") {
                        ForEach(extractor.outputs, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                if !extractor.log.isEmpty {
                    Section("hactool log") {
                        ScrollView(.horizontal) {
                            Text(extractor.log)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                    }
                }

                Section {
                    Text("Use only dumps and keys from your own Switch. Everything runs on-device; temporary files are deleted when extraction finishes, so keep roughly 2× the game's size free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ruina Extractor")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                switch pickerTarget {
                case .game: gameURL = url
                case .update: updateURL = url
                case .keys: keysURL = url
                }
            }
        }
    }

    private func open(_ target: Target) {
        pickerTarget = target
        showPicker = true
    }

    private func pickerRow(title: String, url: URL?, required: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(url?.lastPathComponent ?? (required ? "Tap to choose" : "None"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: url == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                    .foregroundStyle(url == nil ? Color.accentColor : Color.green)
            }
        }
        .disabled(extractor.isRunning)
    }
}
