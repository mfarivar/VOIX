import Foundation

final class WhisperServer {
    static let binary = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private let port = 8178
    private var proc: Process?
    private var model: URL?

    func ensure(model m: URL) {
        if proc?.isRunning == true, model == m { return }
        stop()
        guard let bin = Self.binary else { return }
        // Clear out a server orphaned by a previous crash.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? kill.run(); kill.waitUntilExit()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", m.path, "--host", "127.0.0.1", "--port", "\(port)", "-nt", "-t", "4"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proc = p; model = m; vlog("whisper server started: \(m.lastPathComponent)") }
        catch { vlog("whisper server failed to start: \(error)") }
    }

    func stop() {
        proc?.terminate()
        proc = nil
        model = nil
    }

    /// Synchronous; returns nil if the server isn't running this model or isn't ready yet.
    func transcribe(wav: URL, model m: URL, prompt: String) -> String? {
        guard proc?.isRunning == true, model == m, let audio = try? Data(contentsOf: wav) else { return nil }
        let boundary = "voix-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("language", "en")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        var result: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return }
            result = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("(") }
                .joined(separator: " ")
        }.resume()
        sem.wait()
        return result
    }
}
