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
                let data = (try? Data(contentsOf: logURL)) ?? Data()
                cont.resume(returning: Result(code: code, log: String(decoding: data, as: UTF8.self)))
            }
            thread.stackSize = 16 * 1024 * 1024
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
