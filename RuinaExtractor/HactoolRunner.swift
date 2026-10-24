import Foundation

/// Runs the bundled hactool (C) in-process on a dedicated big-stack thread.
enum HactoolRunner {
    struct Result {
        let code: Int32
        let log: String
    }

    /// `args` excludes argv[0]; it is added here.
    static func run(_ args: [String], home: URL, logURL: URL) async -> Result {
        let argv = ["hactool"] + args
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            let thread = Thread {
                var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
                cargs.append(nil)
                let code = cargs.withUnsafeMutableBufferPointer { buf in
                    hactool_run(Int32(argv.count), buf.baseAddress, home.path, logURL.path)
                }
                for p in cargs { free(p) }
                let log = Self.readLogTail(logURL)
                cont.resume(returning: Result(code: code, log: log))
            }
            thread.stackSize = 4 * 1024 * 1024
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private static func readLogTail(_ url: URL, limit: UInt64 = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            return ""
        }

        let start = end > limit ? end - limit : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(end - start)) ?? Data()
            let prefix = start > 0 ? "[Earlier log output omitted]\n" : ""
            return prefix + String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }
}

/// Follows a log file that another thread is appending to and returns only complete new lines.
final class LogTailer {
    private let url: URL
    private var offset: UInt64 = 0
    private var partial = ""

    init(url: URL) { self.url = url }

    func readNew() -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        if end < offset { offset = 0; partial = "" }
        if end == offset { return "" }
        let take = min(end - offset, 256 * 1024)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(take)) ?? Data()
            offset += UInt64(data.count)
            partial += String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
        guard let newline = partial.lastIndex(of: "\n") else { return "" }
        let complete = String(partial[..<newline])
        partial = String(partial[partial.index(after: newline)...])
        return complete
    }

    func flush() -> String {
        let rest = readNew()
        let tail = partial
        partial = ""
        return tail.isEmpty ? rest : rest + "\n" + tail
    }
}
