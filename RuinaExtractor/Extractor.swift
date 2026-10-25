import Foundation
import UIKit
import MetricKit

struct ExtractionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ConsoleLine: Identifiable {
    let id: Int
    let text: String
}

final class MetricsListener: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        var summaries: [String] = []
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let fg = exits.foregroundExitData
            let bg = exits.backgroundExitData
            summaries.append("[MetricKit] exits fg: normal=\(fg.cumulativeNormalAppExitCount) memoryLimit=\(fg.cumulativeMemoryResourceLimitExitCount) badAccess=\(fg.cumulativeBadAccessExitCount) abnormal=\(fg.cumulativeAbnormalExitCount) illegal=\(fg.cumulativeIllegalInstructionExitCount) watchdog=\(fg.cumulativeAppWatchdogExitCount) | bg: normal=\(bg.cumulativeNormalAppExitCount) memoryLimit=\(bg.cumulativeMemoryResourceLimitExitCount) memoryPressure=\(bg.cumulativeMemoryPressureExitCount) badAccess=\(bg.cumulativeBadAccessExitCount) abnormal=\(bg.cumulativeAbnormalExitCount) watchdog=\(bg.cumulativeAppWatchdogExitCount)")
        }
        post(summaries)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var summaries: [String] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let type = crash.exceptionType?.stringValue ?? "?"
                let signal = crash.signal?.stringValue ?? "?"
                let reason = crash.terminationReason ?? "none"
                summaries.append("[MetricKit] crash report: exception_type=\(type) signal=\(signal) termination_reason=\(reason)")
            }
            let name = "RuinaExtractor-metrickit-\(Int(Date().timeIntervalSince1970)).json"
            try? payload.jsonRepresentation().write(to: docs.appendingPathComponent(name))
            summaries.append("[MetricKit] full diagnostic payload saved to Documents/\(name)")
        }
        post(summaries)
    }

    private func post(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        Task { @MainActor in
            for line in lines { ConsoleLog.shared.log(line) }
        }
    }
}

/// Persistent console: everything is appended to Documents/RuinaExtractor-console.log as it happens,
/// so it survives the app being killed. A marker file detects runs that never finished.
@MainActor
final class ConsoleLog: ObservableObject {
    static let shared = ConsoleLog()

    @Published private(set) var lines: [ConsoleLine] = []
    @Published var interruptedSummary: String?

    let fileURL: URL
    private let markerURL: URL
    private let stampFormatter = DateFormatter()
    private let uiLimit = 600
    private let metrics = MetricsListener()
    private var observers: [NSObjectProtocol] = []
    private var fd: Int32 = -1
    private var nextID = 0
    private var stage = "idle"
    private var sessionInfo = ""
    private var sessionActive = false

    private init() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = docs.appendingPathComponent("RuinaExtractor-console.log")
        markerURL = support.appendingPathComponent("run-in-progress.marker")
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "HH:mm:ss.SSS"

        trimFileIfNeeded()
        let wasInterrupted = fm.fileExists(atPath: markerURL.path)
        if wasInterrupted { loadTail() }
        fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        hactool_install_crash_handler(fileURL.path)

        if wasInterrupted {
            let marker = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
            let parts = marker.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let lastStage = parts.first ?? "unknown"
            let info = parts.count > 1 ? parts[1] : ""
            try? fm.removeItem(at: markerURL)
            log("---- previous run ended unexpectedly during: \(lastStage) \(info) ----")
            interruptedSummary = "The last run never finished: the app was killed or crashed during \u{201C}\(lastStage)\u{201D}. A [CRASH] block in the console means a real crash (with a backtrace). If there is none, look at the last \u{2665} lines: avail near 0 MB means iOS killed the app for memory, and a background warning means it was suspended."
        }

        log("=== launched: iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model), RAM \(Self.bytes(Int64(ProcessInfo.processInfo.physicalMemory))) | \(memorySnapshot())")
        observeSystemEvents()
        MXMetricManager.shared.add(metrics)
    }

    static func bytes(_ count: Int64) -> String {
        count < 0 ? "?" : ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    func freeDiskBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }

    func memorySnapshot() -> String {
        let footprint = Int64(hactool_process_footprint())
        let avail = Int64(hactool_available_memory())
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "SERIOUS"
        case .critical: thermal = "CRITICAL"
        @unknown default: thermal = "?"
        }
        return "footprint=\(Self.bytes(footprint)) avail=\(Self.bytes(avail)) disk_free=\(Self.bytes(freeDiskBytes())) thermal=\(thermal)"
    }

    func heartbeat() {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "BACKGROUND"
        @unknown default: state = "?"
        }
        log("\u{2665} [\(stage)] \(memorySnapshot()) app=\(state)")
    }

    func log(_ text: String) {
        guard !text.isEmpty else { return }
        let stamp = stampFormatter.string(from: Date())
        var added = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = "\(stamp) \(raw)"
            appendToFile(line + "\n")
            lines.append(ConsoleLine(id: nextID, text: line))
            nextID += 1
            added = true
        }
        if added, lines.count > uiLimit { lines.removeFirst(lines.count - uiLimit) }
    }

    func setStage(_ newStage: String) {
        stage = newStage
        hactool_set_stage(newStage)
        if sessionActive { writeMarker() }
    }

    func beginSession(_ info: String) {
        sessionInfo = info
        sessionActive = true
        writeMarker()
        log("=== run started: \(info)")
    }

    func endSession(_ outcome: String) {
        sessionActive = false
        try? FileManager.default.removeItem(at: markerURL)
        log("=== run \(outcome)")
    }

    func clearView() { lines.removeAll() }
    func dismissInterrupted() { interruptedSummary = nil }
    func copyText() -> String { lines.map(\.text).joined(separator: "\n") }

    private func writeMarker() {
        try? "\(stage)\n\(sessionInfo)\n".write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private func appendToFile(_ text: String) {
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    private func trimFileIfNeeded() {
        let limit = 1_024 * 1_024
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber,
              size.intValue > limit,
              let reader = try? FileHandle(forReadingFrom: fileURL) else { return }
        let end = (try? reader.seekToEnd()) ?? 0
        let start = end > 512 * 1_024 ? end - 512 * 1_024 : 0
        try? reader.seek(toOffset: start)
        let tail = (try? reader.read(upToCount: Int(end - start))) ?? Data()
        try? reader.close()
        try? tail.write(to: fileURL, options: .atomic)
    }

    private func loadTail() {
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? reader.close() }
        let end = (try? reader.seekToEnd()) ?? 0
        let start = end > 64 * 1_024 ? end - 64 * 1_024 : 0
        try? reader.seek(toOffset: start)
        let data = (try? reader.read(upToCount: Int(end - start))) ?? Data()
        let tail = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).suffix(150)
        for raw in tail {
            lines.append(ConsoleLine(id: nextID, text: String(raw)))
            nextID += 1
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[WARN] MEMORY WARNING from iOS | \(self?.memorySnapshot() ?? "")") }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[app] resigned active (lock screen, control center or app switcher)") }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[WARN] app entered BACKGROUND: iOS can suspend or kill it now") }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[app] returning to foreground") }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[WARN] app is terminating") }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.log("[WARN] thermal state changed | \(self?.memorySnapshot() ?? "")") }
        })
    }
}

@MainActor
final class Extractor: ObservableObject {
    @Published var status = "Pick a game dump and your prod.keys." {
        didSet {
            guard status != oldValue else { return }
            console.log("[status] \(status)")
            console.setStage(status)
        }
    }
    @Published var isRunning = false
    @Published var outputs: [URL] = []
    @Published var outputFolder: URL?

    let console = ConsoleLog.shared
    private let fm = FileManager.default

    init() {
        purgeStaleWorkDirectories()
    }

    private func purgeStaleWorkDirectories() {
        let launched = Date()
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
            var removed = 0
            for url in items where url.lastPathComponent.hasPrefix("work-") {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                guard created < launched else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            if removed > 0 {
                await ConsoleLog.shared.log("Removed \(removed) leftover work folder(s) from an earlier interrupted run.")
            }
        }
    }

    // MARK: - Public entry point

    func run(game: URL, update: URL?, keys: URL) async {
        guard !isRunning else { return }
        isRunning = true
        outputs = []
        outputFolder = nil
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isRunning = false
        }
        console.beginSession("game=\(game.lastPathComponent) update=\(update?.lastPathComponent ?? "none")")

        let gameScoped = game.startAccessingSecurityScopedResource()
        let updateScoped = update?.startAccessingSecurityScopedResource() ?? false
        let keysScoped = keys.startAccessingSecurityScopedResource()
        defer {
            if gameScoped { game.stopAccessingSecurityScopedResource() }
            if updateScoped { update?.stopAccessingSecurityScopedResource() }
            if keysScoped { keys.stopAccessingSecurityScopedResource() }
        }

        let work = fm.temporaryDirectory.appendingPathComponent("work-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        do {
            try await extract(game: game, update: update, keys: keys, work: work)
            console.endSession("completed")
        } catch {
            status = "Failed: \(error.localizedDescription)"
            append("[ERROR] \(error.localizedDescription)")
            console.endSession("failed")
        }
    }

    // MARK: - Pipeline

    private func extract(game: URL, update: URL?, keys: URL, work: URL) async throws {
        let gameBytes = Int64(size(game))
        let updateBytes = update.map { Int64(size($0)) } ?? 0
        append("Game: \(game.lastPathComponent) (\(ConsoleLog.bytes(gameBytes)))")
        if let update { append("Update: \(update.lastPathComponent) (\(ConsoleLog.bytes(updateBytes)))") }
        append("Start: \(console.memorySnapshot())")
        let freeBytes = console.freeDiskBytes()
        if freeBytes >= 0, freeBytes < (gameBytes + updateBytes) * 2 {
            append("[WARN] Only \(ConsoleLog.bytes(freeBytes)) free; extraction needs roughly 2x the input size.")
        }

        // 1. HOME with .switch/prod.keys (hactool looks there, and for title.keys)
        status = "Preparing keys…"
        let home = work.appendingPathComponent("home")
        let switchDir = home.appendingPathComponent(".switch")
        try fm.createDirectory(at: switchDir, withIntermediateDirectories: true)
        let keysCopy = switchDir.appendingPathComponent("prod.keys")
        let keysData = try Data(contentsOf: keys)
        let keysText = String(decoding: keysData, as: UTF8.self)
        guard keysText.contains("header_key"), keysText.contains("master_key_") else {
            throw ExtractionError("That file doesn't look like a prod.keys (no header_key / master_key_xx entries).")
        }
        try keysData.write(to: keysCopy)
        let logURL = work.appendingPathComponent("hactool.log")

        var updateDir: URL?
        if let update {
            status = "Unpacking \(update.lastPathComponent)…"
            let dir = work.appendingPathComponent("update")
            try await unpackContainer(update, into: dir, keys: keysCopy, home: home, logURL: logURL)
            updateDir = dir
        }

        status = "Unpacking \(game.lastPathComponent)… (this can take a while)"
        let baseDir = work.appendingPathComponent("base")
        try await unpackContainer(game, into: baseDir, keys: keysCopy, home: home, logURL: logURL)

        var lines: [String] = []
        for dir in [updateDir, baseDir].compactMap({ $0 }) {
            for tik in files(in: dir, ext: "tik") {
                do {
                    let t = try TicketParser.parse(try Data(contentsOf: tik))
                    lines.append("\(t.rightsID) = \(t.titleKey)")
                } catch {
                    append("[WARN] \(tik.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !lines.isEmpty {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: switchDir.appendingPathComponent("title.keys"), atomically: true, encoding: .utf8)
            append("Loaded \(lines.count) title key(s) from tickets.")
        }

        status = "Locating the Program NCA…"
        var updateProgram: ProgramNCA?
        if let updateDir {
            updateProgram = try await findProgramNCA(in: updateDir, keys: keysCopy, home: home, logURL: logURL)
            if updateProgram == nil {
                append("[WARN] No Program NCA found in the update file. Check its title key / ticket. Using the BASE game instead.")
            }
        }
        let baseProgram = try await findProgramNCA(in: baseDir, keys: keysCopy, home: home, logURL: logURL)
        if baseProgram == nil && updateProgram == nil {
            throw ExtractionError("No Program NCA found in the game or update file. Check that prod.keys is new enough for this dump (master key / keygen revision).")
        }
        if baseProgram == nil {
            append("[WARN] No Program NCA found in the base game, so the update's patch RomFS has nothing to patch against.")
        }

        status = "Extracting ExeFS and RomFS… (this can take a while)"
        let exefsDir = work.appendingPathComponent("exefs")
        let romfsDir = work.appendingPathComponent("romfs")
        let mainCheck = exefsDir.appendingPathComponent("main")

        var exefsProgram: ProgramNCA?
        if let upd = updateProgram {
            let ok = await extractSection(flag: "--exefsdir", nca: upd.url, into: exefsDir, baseNCA: baseProgram?.url,
                                          allowWithoutBase: true, stage: "Extracting update ExeFS", keys: keysCopy, home: home, logURL: logURL)
            if ok && fm.fileExists(atPath: mainCheck.path) {
                exefsProgram = upd
            } else {
                append("[WARN] Update ExeFS could not be extracted; falling back to the BASE game's ExeFS.")
            }
        }
        if exefsProgram == nil, let base = baseProgram {
            let ok = await extractSection(flag: "--exefsdir", nca: base.url, into: exefsDir, baseNCA: nil,
                                          allowWithoutBase: true, stage: "Extracting base ExeFS", keys: keysCopy, home: home, logURL: logURL)
            if ok && fm.fileExists(atPath: mainCheck.path) { exefsProgram = base }
        }
        guard let targetProgram = exefsProgram else {
            throw ExtractionError("hactool failed while extracting ExeFS from both the update and the base game. See log.")
        }
        let exefsFromUpdate = updateProgram != nil && targetProgram.url == updateProgram?.url

        var romfsNote = "no-romfs"
        if let upd = updateProgram {
            let ok = await extractSection(flag: "--romfsdir", nca: upd.url, into: romfsDir, baseNCA: baseProgram?.url,
                                          allowWithoutBase: false, stage: "Extracting update RomFS", keys: keysCopy, home: home, logURL: logURL)
            if ok {
                romfsNote = "update-romfs"
            } else {
                append("[WARN] Update RomFS could not be extracted; falling back to the BASE game's RomFS (metadata may be older than the update).")
            }
        }
        if romfsNote == "no-romfs", let base = baseProgram {
            let ok = await extractSection(flag: "--romfsdir", nca: base.url, into: romfsDir, baseNCA: nil,
                                          allowWithoutBase: true, stage: "Extracting base RomFS", keys: keysCopy, home: home, logURL: logURL)
            if ok { romfsNote = "base-romfs" }
        }

        append("Program NCA: \(targetProgram.url.lastPathComponent)  (Title ID \(targetProgram.titleID))")
        append("ExeFS source: \(exefsFromUpdate ? "update" : "base")  |  RomFS source: \(romfsNote)")
        if updateDir != nil && !exefsFromUpdate {
            append("[WARN] ExeFS came from the BASE game, so its build ID will not match the updated game.")
        }

        let mainFile = exefsDir.appendingPathComponent("main")
        guard fm.fileExists(atPath: mainFile.path) else {
            throw ExtractionError("ExeFS was extracted but contains no 'main'. See log.")
        }
        if let id = buildID(of: mainFile) { append("main build ID: \(id)") }

        // 6. Decompress main (NSO) for IL2CPP tooling
        status = "Decompressing main…"
        let uncompressed = work.appendingPathComponent("main.uncompressed")
        let r2 = await runHactool(["-k", keysCopy.path, "--disablekeywarns", "-t", "nso0",
                                   "--uncompressed=\(uncompressed.path)", mainFile.path],
                                  stage: "Decompressing main NSO", home: home, logURL: logURL)
        if r2.code != 0 || !fm.fileExists(atPath: uncompressed.path) {
            append("[WARN] Could not produce an uncompressed main.")
        }

        // 7. Find global-metadata.dat
        let metadata = find(named: "global-metadata.dat", under: romfsDir)
        if metadata == nil { append("[WARN] global-metadata.dat not found (\(romfsNote)). Continuing with ExeFS only.") }
        let unityFiles = ["globalgamemanagers", "boot.config"].compactMap { name -> URL? in
            let found = find(named: name, under: romfsDir)
            if found == nil { append("[WARN] \(name) not found in the RomFS (\(romfsNote)).") }
            return found
        }

        // 8. Copy results into Documents/Extracted/<TitleID>
        status = "Saving results…"
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent("Extracted/\(targetProgram.titleID)\(exefsFromUpdate ? "-patched" : "")")
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var results: [URL] = []
        if let metadata {
            let metaOut = out.appendingPathComponent("global-metadata.dat")
            try fm.copyItem(at: metadata, to: metaOut); results.append(metaOut)
        }

        for src in unityFiles {
            let dst = out.appendingPathComponent(src.lastPathComponent)
            try fm.copyItem(at: src, to: dst); results.append(dst)
        }

        let exefsOut = out.appendingPathComponent("exefs")
        try fm.copyItem(at: exefsDir, to: exefsOut)
        results.append(exefsOut.appendingPathComponent("main"))
        let npdm = exefsOut.appendingPathComponent("main.npdm")
        if fm.fileExists(atPath: npdm.path) { results.append(npdm) }

        status = "Saving RomFS Data folder…"
        let topLevel = (try? fm.contentsOfDirectory(at: romfsDir, includingPropertiesForKeys: nil)) ?? []
        if let dataDir = topLevel.first(where: { $0.lastPathComponent.lowercased() == "data" }) {
            let dataOut = out.appendingPathComponent("Data")
            do {
                try fm.moveItem(at: dataDir, to: dataOut)
            } catch {
                append("[WARN] Move of Data folder failed (\(error.localizedDescription)); copying instead.")
                try fm.copyItem(at: dataDir, to: dataOut)
            }
            results.append(dataOut)
            let count = fm.enumerator(at: dataOut, includingPropertiesForKeys: nil)?.allObjects.count ?? 0
            append("Saved RomFS Data folder (\(count) items).")
        } else {
            append("[WARN] No Data folder found at the top level of the RomFS (\(romfsNote)).")
        }

        status = "Saving results…"
        if fm.fileExists(atPath: uncompressed.path) {
            let u = out.appendingPathComponent("main.uncompressed")
            try fm.copyItem(at: uncompressed, to: u); results.append(u)
        }

        outputs = results
        outputFolder = out
        status = "Done. Files are in Files › On My iPhone › RuinaExtractor › Extracted."
    }

    private func runHactool(_ args: [String], stage: String, home: URL, logURL: URL, echo: Bool = true) async -> HactoolRunner.Result {
        try? fm.removeItem(at: logURL)
        console.setStage(stage)
        console.log("\u{25B6} \(stage)")
        console.heartbeat()
        let tailer = LogTailer(url: logURL)
        let monitor = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { break }
                if echo { self.console.log(tailer.readNew()) }
                ticks += 1
                if ticks % 6 == 0 { self.console.heartbeat() }
            }
        }
        let result = await HactoolRunner.run(args, home: home, logURL: logURL)
        monitor.cancel()
        if echo { console.log(tailer.flush()) }
        console.log("\u{25A0} \(stage) exit=\(result.code) | \(console.memorySnapshot())")
        return result
    }

    // MARK: - Steps

    private func unpackContainer(_ url: URL, into dir: URL, keys: URL, home: URL, logURL: URL) async throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let args: [String]
        switch try containerKind(url) {
        case .xci:
            args = ["-k", keys.path, "--disablekeywarns", "-t", "xci", "--securedir=\(dir.path)", url.path]
        case .nsp:
            args = ["-k", keys.path, "--disablekeywarns", "-t", "pfs0", "--pfs0dir=\(dir.path)", url.path]
        }
        let r = await runHactool(args, stage: "Unpacking \(url.lastPathComponent)", home: home, logURL: logURL)
        guard r.code == 0 else { throw ExtractionError("hactool failed to unpack \(url.lastPathComponent) (exit \(r.code)).") }
        guard !files(in: dir, ext: "nca").isEmpty else {
            throw ExtractionError("No NCA files were found inside \(url.lastPathComponent).")
        }
    }

    private func extractSection(flag: String, nca: URL, into dir: URL, baseNCA: URL?, allowWithoutBase: Bool,
                                stage: String, keys: URL, home: URL, logURL: URL) async -> Bool {
        var variants: [[String]] = []
        if let baseNCA { variants.append(["--basenca=\(baseNCA.path)"]) }
        if baseNCA == nil || allowWithoutBase { variants.append([]) }
        for (index, extra) in variants.enumerated() {
            try? fm.removeItem(at: dir)
            let args = ["-k", keys.path, "--disablekeywarns", "-t", "nca"] + extra + ["\(flag)=\(dir.path)", nca.path]
            let label = index == 0 ? stage : "\(stage) (retry without base NCA)"
            let r = await runHactool(args, stage: label, home: home, logURL: logURL)
            if r.code == 0 && hasContent(dir) { return true }
        }
        try? fm.removeItem(at: dir)
        return false
    }

    private func hasContent(_ dir: URL) -> Bool {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        return e.nextObject() != nil
    }

    private func buildID(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: 0x40)) != nil, let d = try? h.read(upToCount: 0x20), d.count == 0x20 else { return nil }
        return d.map { String(format: "%02X", $0) }.joined()
    }

    private enum ContainerKind { case xci, nsp }

    private func containerKind(_ url: URL) throws -> ContainerKind {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let head = try h.read(upToCount: 4) ?? Data()
        try h.seek(toOffset: 0x100)
        let xciMagic = try h.read(upToCount: 4) ?? Data()
        if head == Data("PFS0".utf8) { return .nsp }
        if xciMagic == Data("HEAD".utf8) { return .xci }
        throw ExtractionError("\(url.lastPathComponent) is neither an NSP (PFS0) nor an XCI.")
    }

    private struct ProgramNCA { let url: URL; let titleID: String }

    /// Checks NCA headers (largest first) until one reports "Content Type: Program".
    private func findProgramNCA(in dir: URL, keys: URL, home: URL, logURL: URL) async throws -> ProgramNCA? {
        let candidates = files(in: dir, ext: "nca")
            .filter { !$0.lastPathComponent.hasSuffix(".cnmt.nca") }
            .sorted { size($0) > size($1) }
        append("Found \(candidates.count) NCA file(s) in \(dir.lastPathComponent)")
        var shownFailures = 0
        for nca in candidates {
            let r = await runHactool(["-k", keys.path, "--disablekeywarns", "-t", "nca", nca.path],
                                     stage: "Inspecting \(nca.lastPathComponent)", home: home, logURL: logURL, echo: false)
            var type: String?, tid: String?
            for line in r.log.split(separator: "\n") {
                if line.hasPrefix("Content Type:") { type = line.dropFirst("Content Type:".count).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("Title ID:") { tid = line.dropFirst("Title ID:".count).trimmingCharacters(in: .whitespaces) }
            }
            append("  \(nca.lastPathComponent): \(type ?? "unknown type"), \(ConsoleLog.bytes(Int64(size(nca))))")
            if type == nil, shownFailures < 3 {
                shownFailures += 1
                let tail = r.log.split(separator: "\n").suffix(12).joined(separator: "\n")
                append("  hactool exit=\(r.code), output:\n\(tail.isEmpty ? "(empty)" : tail)")
            }
            if type == "Program", let tid { return ProgramNCA(url: nca, titleID: tid) }
        }
        return nil
    }

    // MARK: - Helpers

    private func files(in dir: URL, ext: String) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == ext }
    }

    private func size(_ url: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    private func find(named name: String, under dir: URL) -> URL? {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name { return url }
        return nil
    }

    private func append(_ text: String) { console.log(text) }
}
