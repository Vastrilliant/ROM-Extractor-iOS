import Foundation

struct ExtractionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class Extractor: ObservableObject {
    @Published var status = "Pick a game dump and your prod.keys."
    @Published var log = ""
    @Published var isRunning = false
    @Published var outputs: [URL] = []
    @Published var outputFolder: URL?

    private let fm = FileManager.default

    // MARK: - Public entry point

    func run(game: URL, update: URL?, keys: URL) async {
        guard !isRunning else { return }
        isRunning = true
        outputs = []
        outputFolder = nil
        log = ""
        defer { isRunning = false }

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
        } catch {
            status = "Failed: \(error.localizedDescription)"
            append("\n[ERROR] \(error.localizedDescription)\n")
        }
    }

    // MARK: - Pipeline

    private func extract(game: URL, update: URL?, keys: URL, work: URL) async throws {
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

        // 2. Unpack the container(s) into NCAs (+ tickets for NSPs)
        status = "Unpacking \(game.lastPathComponent)… (this can take a while)"
        let baseDir = work.appendingPathComponent("base")
        try await unpackContainer(game, into: baseDir, keys: keysCopy, home: home, logURL: logURL)

        var updateDir: URL?
        if let update {
            status = "Unpacking \(update.lastPathComponent)…"
            let dir = work.appendingPathComponent("update")
            try await unpackContainer(update, into: dir, keys: keysCopy, home: home, logURL: logURL)
            updateDir = dir
        }

        // 3. Tickets -> title.keys (needed for NSP contents using rights-ID crypto)
        var lines: [String] = []
        for dir in [baseDir, updateDir].compactMap({ $0 }) {
            for tik in files(in: dir, ext: "tik") {
                do {
                    let t = try TicketParser.parse(try Data(contentsOf: tik))
                    lines.append("\(t.rightsID) = \(t.titleKey)")
                } catch {
                    append("[WARN] \(tik.lastPathComponent): \(error.localizedDescription)\n")
                }
            }
        }
        if !lines.isEmpty {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: switchDir.appendingPathComponent("title.keys"), atomically: true, encoding: .utf8)
            append("Loaded \(lines.count) title key(s) from tickets.\n")
        }

        // 4. Locate the Program NCA(s)
        status = "Locating the Program NCA…"
        guard let baseProgram = try await findProgramNCA(in: baseDir, keys: keysCopy, home: home, logURL: logURL) else {
            throw ExtractionError("No Program NCA found in the game file. Check that prod.keys is new enough for this dump (master key / keygen revision).")
        }
        var targetProgram = baseProgram
        var basePath: String?
        if let updateDir {
            guard let upd = try await findProgramNCA(in: updateDir, keys: keysCopy, home: home, logURL: logURL) else {
                throw ExtractionError("No Program NCA found in the update file.")
            }
            targetProgram = upd
            basePath = baseProgram.url.path
        }
        append("Program NCA: \(targetProgram.url.lastPathComponent)  (Title ID \(targetProgram.titleID))\n")

        // 5. Extract ExeFS + RomFS
        status = "Extracting ExeFS and RomFS… (this can take a while)"
        let exefsDir = work.appendingPathComponent("exefs")
        let romfsDir = work.appendingPathComponent("romfs")
        var args = ["-k", keysCopy.path, "--disablekeywarns", "-t", "nca",
                    "--exefsdir=\(exefsDir.path)", "--romfsdir=\(romfsDir.path)"]
        if let basePath { args.append("--basenca=\(basePath)") }
        args.append(targetProgram.url.path)
        let r = await HactoolRunner.run(args, home: home, logURL: logURL)
        append(trimmed(r.log))
        guard r.code == 0 else { throw ExtractionError("hactool failed while extracting the Program NCA (exit \(r.code)). See log.") }

        let mainFile = exefsDir.appendingPathComponent("main")
        guard fm.fileExists(atPath: mainFile.path) else {
            throw ExtractionError("ExeFS was extracted but contains no 'main'. See log.")
        }

        // 6. Decompress main (NSO) for IL2CPP tooling
        status = "Decompressing main…"
        let uncompressed = work.appendingPathComponent("main.uncompressed")
        let r2 = await HactoolRunner.run(["-k", keysCopy.path, "--disablekeywarns", "-t", "nso0",
                                          "--uncompressed=\(uncompressed.path)", mainFile.path],
                                         home: home, logURL: logURL)
        if r2.code != 0 || !fm.fileExists(atPath: uncompressed.path) {
            append("[WARN] Could not produce an uncompressed main.\n")
        }

        // 7. Find global-metadata.dat
        guard let metadata = find(named: "global-metadata.dat", under: romfsDir) else {
            throw ExtractionError("Extraction finished but global-metadata.dat wasn't found in RomFS. Is this an IL2CPP build?")
        }

        // 8. Copy results into Documents/Extracted/<TitleID>
        status = "Saving results…"
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent("Extracted/\(targetProgram.titleID)\(updateDir != nil ? "-patched" : "")")
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var results: [URL] = []
        let metaOut = out.appendingPathComponent("global-metadata.dat")
        try fm.copyItem(at: metadata, to: metaOut); results.append(metaOut)

        let exefsOut = out.appendingPathComponent("exefs")
        try fm.copyItem(at: exefsDir, to: exefsOut)
        results.append(exefsOut.appendingPathComponent("main"))
        let npdm = exefsOut.appendingPathComponent("main.npdm")
        if fm.fileExists(atPath: npdm.path) { results.append(npdm) }

        if fm.fileExists(atPath: uncompressed.path) {
            let u = out.appendingPathComponent("main.uncompressed")
            try fm.copyItem(at: uncompressed, to: u); results.append(u)
        }

        outputs = results
        outputFolder = out
        status = "Done. Files are in Files › On My iPhone › RuinaExtractor › Extracted."
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
        let r = await HactoolRunner.run(args, home: home, logURL: logURL)
        append(trimmed(r.log))
        guard r.code == 0 else { throw ExtractionError("hactool failed to unpack \(url.lastPathComponent) (exit \(r.code)).") }
        guard !files(in: dir, ext: "nca").isEmpty else {
            throw ExtractionError("No NCA files were found inside \(url.lastPathComponent).")
        }
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
            .prefix(8)
        for nca in candidates {
            let r = await HactoolRunner.run(["-k", keys.path, "--disablekeywarns", "-t", "nca", nca.path],
                                            home: home, logURL: logURL)
            var type: String?, tid: String?
            for line in r.log.split(separator: "\n") {
                if line.hasPrefix("Content Type:") { type = line.dropFirst("Content Type:".count).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("Title ID:") { tid = line.dropFirst("Title ID:".count).trimmingCharacters(in: .whitespaces) }
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

    private func append(_ text: String) { log += text }

    private func trimmed(_ text: String) -> String {
        text.count > 12000 ? "…\n" + text.suffix(12000) : text
    }
}
