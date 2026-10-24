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

                Section {
                    ConsoleView(console: extractor.console)
                } header: {
                    Text("Console")
                } footer: {
                    Text("Also saved to Files \u{203A} On My iPhone \u{203A} RuinaExtractor \u{203A} RuinaExtractor-console.log")
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

struct ConsoleView: View {
    @ObservedObject var console: ConsoleLog
    @State private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = console.interruptedSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Dismiss") { console.dismissInterrupted() }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(console.lines) { line in
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(for: line.text))
                                .fixedSize(horizontal: true, vertical: false)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 320)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: console.lines.last?.id) { id in
                    if follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            HStack(spacing: 14) {
                Button { UIPasteboard.general.string = console.copyText() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: console.fileURL) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { console.clearView() } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)

            Toggle("Follow latest", isOn: $follow)
                .font(.footnote)
        }
    }

    private func color(for text: String) -> Color {
        if text.contains("[CRASH]") || text.contains("[ERROR]") || text.contains("ended unexpectedly") { return .red }
        if text.contains("[WARN]") { return .orange }
        if text.contains("\u{2665}") { return .secondary }
        if text.contains("\u{25B6}") || text.contains("\u{25A0}") || text.contains("===") { return .blue }
        return .primary
    }
}
