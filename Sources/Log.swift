import Foundation

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VOIX.log")

/// Appends a diagnostic line. Never log transcript text — it may be private.
func vlog(_ msg: String) {
    let url = logURL
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Starts a fresh log once it passes 1 MB.
func trimLog() {
    let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    if size > 1_000_000 { try? FileManager.default.removeItem(at: logURL) }
}
