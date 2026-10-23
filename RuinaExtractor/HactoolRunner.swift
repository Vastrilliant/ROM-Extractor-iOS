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
