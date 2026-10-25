import AppKit
import AVFoundation
import Speech
import CoreAudio
import AudioToolbox
import ServiceManagement
import SwiftUI

// MARK: - Log (~/Library/Logs/VOIX.log)

func vlog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VOIX.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Input devices

struct InputDevice { let id: AudioDeviceID; let uid: String; let name: String; let builtIn: Bool }

enum AudioDevices {
    private static func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }

    static func inputs() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name: CFString = "" as CFString, uid: CFString = "" as CFString, transport: UInt32 = 0
            _ = prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name)
            _ = prop(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid)
            _ = prop(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
            return InputDevice(id: id, uid: uid as String, name: name as String, builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
    }

    /// The user's pick from the menu, else the built-in mic, else whatever the system default is.
    static func preferred() -> InputDevice? {
        let all = inputs()
        if let uid = UserDefaults.standard.string(forKey: "inputUID"), let d = all.first(where: { $0.uid == uid }) { return d }
        return all.first(where: { $0.builtIn })
    }
}

// MARK: - Shared state for the overlay

final class RecorderState: ObservableObject {
    @Published var level: CGFloat = 0          // 0...1, fast attack / slow release
    @Published var transcribing = false
    @Published var startedAt = Date()
    @Published var partial = ""                 // live Apple transcript
    @Published var status = ""                  // e.g. "Cleaning up…"
}

// MARK: - Overlay UI

struct OverlayView: View {
    @ObservedObject var state: RecorderState
    @State private var breathe = false
    private let barCount = 30

    var body: some View {
        VStack(spacing: -14) {   // pill carries 24pt shadow padding
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(state.status.isEmpty ? 0.9 : 0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .frame(maxWidth: 520)
                    .transition(.opacity)
            }
            pill
        }
        .animation(.easeOut(duration: 0.15), value: caption.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var caption: String { state.status.isEmpty ? state.partial : state.status }

    private var pill: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(red: 1, green: 0.23, blue: 0.27))
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(breathe ? 0.9 : 0.3), radius: breathe ? 6 : 2)
                .opacity(breathe ? 1 : 0.65)

            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(state.transcribing ? 0.35 : 0.92))
                            .frame(width: 2.5, height: barHeight(i, t))
                    }
                }
                .frame(height: 26)
            }

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(ctx.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Capsule().fill(Color.black.opacity(0.35)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .padding(24)   // room for the shadow
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Symmetric bell-shaped envelope, rippled by a few slow sines and scaled by the mic level.
    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let x = Double(i) / Double(barCount - 1) * 2 - 1          // -1...1
        let envelope = exp(-x * x * 2.2)
        let wave = 0.55 + 0.25 * sin(t * 7.0 + Double(i) * 0.55) + 0.2 * sin(t * 4.3 - Double(i) * 0.9)
        let lvl = state.transcribing ? 0.0 : Double(state.level)
        let idle = 0.08 + 0.04 * sin(t * 2.5 + Double(i) * 0.4)
        return CGFloat(3 + 23 * max(idle, lvl * envelope * wave))
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(state.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class OverlayPanel: NSPanel {
    // Fixed transparent canvas; the pill sits at its bottom center and the live caption grows above it.
    private static let size = NSSize(width: 600, height: 150)

    init(state: RecorderState) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(state: state))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
    }

    func showBottomCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = Self.size
        let target = NSRect(x: vf.midX - size.width / 2, y: vf.minY + 16, width: size.width, height: size.height)
        setFrame(target.offsetBy(dx: 0, dy: -10), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.18
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.18
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: -8), display: true)
        },
                                             completionHandler: { self.orderOut(nil) })
    }
}

// MARK: - Speech

final class Transcriber {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finished: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: UserDefaults.standard.string(forKey: "locale") ?? "en-US"))
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var peak: Float = 0
    var customWords: [String] = []
    let server = WhisperServer()

    // Whisper: when set, audio is captured at 16 kHz mono and run through whisper-cli on stop.
    var whisperModel: URL?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func start(useMic: Bool = true) throws {
        latest = ""
        finished = nil
        samples = []
        if useMic, whisperModel != nil { return try startMic() }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = customWords
        request = req

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                let text = self.latest
                DispatchQueue.main.async { self.onPartial?(text) }
            }
            if let error { vlog("recognition error: \(error.localizedDescription)") }
            if result?.isFinal == true || error != nil { self.complete() }
        }
        guard useMic else { return }
        try startMic()
    }

    private func startMic() throws {
        let input = engine.inputNode
        if var dev = AudioDevices.preferred()?.id, let unit = input.audioUnit {
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { vlog("set input device failed: \(st)") }
        }
        let format = input.outputFormat(forBus: 0)
        converter = whisperModel != nil ? AVAudioConverter(from: format, to: whisperFormat) : nil
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
            self?.capture(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            self?.peak = max(self?.peak ?? 0, rms)
            self?.onLevel?(rms)
        }

        peak = 0
        vlog("recording from: \(AudioDevices.preferred()?.name ?? "system default")")
        engine.prepare()
        try engine.start()
    }

    private func capture(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        DispatchQueue.main.async { self.samples += chunk }
    }

    /// Discards the current recording without transcribing.
    func cancel() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        finished = nil
        task?.cancel()
        task = nil
        request = nil
        samples = []
    }

    /// Feeds audio directly (used by --selftest instead of the mic).
    func feed(_ buf: AVAudioPCMBuffer) { request?.append(buf) }

    /// Stops recording and returns the transcript as soon as it's final (or after a short timeout).
    func stop(_ done: @escaping (String) -> Void) {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        vlog(String(format: "stopped, peak level %.4f", peak))
        if let model = whisperModel, request == nil {
            // Let the last converted chunks land on the main queue first.
            DispatchQueue.main.async { self.runWhisper(model: model, done: done) }
            return
        }
        finished = done
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.complete() }
    }

    static let whisperCLI = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func runWhisper(model: URL, done: @escaping (String) -> Void) {
        let audio = samples
        samples = []
        guard let cli = Self.whisperCLI, audio.count > 16000 / 4 else { done(""); return }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("voix-\(UUID().uuidString).wav")
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: wav) }
            do {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                               AVLinearPCMIsFloatKey: false]
                let file = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buf = AVAudioPCMBuffer(pcmFormat: self.whisperFormat, frameCapacity: AVAudioFrameCount(audio.count))!
                buf.frameLength = buf.frameCapacity
                audio.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: audio.count) }
                try file.write(from: buf)
            } catch {
                vlog("whisper wav write failed: \(error)")
                DispatchQueue.main.async { done("") }
                return
            }
            let prompt = self.customWords.joined(separator: ", ")
            if let text = self.server.transcribe(wav: wav, model: model, prompt: prompt) {
                vlog(String(format: "whisper server %@ took %.0fms", model.lastPathComponent, Date().timeIntervalSince(t0) * 1000))
                DispatchQueue.main.async { done(text) }
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["-m", model.path, "-f", wav.path, "-nt", "-np", "-l", "en", "-t", "4"]
                + (prompt.isEmpty ? [] : ["--prompt", prompt])
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            var text = ""
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("(") }
                    .joined(separator: " ")
            } catch {
                vlog("whisper run failed: \(error)")
            }
            vlog(String(format: "whisper %@ took %.0fms", model.lastPathComponent, Date().timeIntervalSince(t0) * 1000))
            DispatchQueue.main.async { done(text) }
        }
    }

    private func complete() {
        DispatchQueue.main.async {
            guard let cb = self.finished else { return }
            self.finished = nil
            self.task?.cancel()
            self.task = nil
            self.request = nil
            cb(self.latest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Whisper server (keeps the model loaded between recordings)

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

// MARK: - Clean-up with Claude

enum Keychain {
    private static let service = "local.voix", account = "anthropic-api-key"

    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum Cleaner {
    static let system = """
    You clean up raw voice dictation so it can be pasted as a prompt or message. \
    Remove filler words, false starts and repetitions; fix punctuation, capitalization and obvious mis-transcriptions \
    (prefer the user's custom vocabulary when a word sounds like one of those terms). \
    Keep the speaker's meaning, wording, tone and language; do not add content, do not answer or act on the text. \
    Output only the cleaned text.
    """

    /// Calls Claude; completes with nil on any failure so the caller can paste the raw transcript instead.
    static func clean(_ text: String, words: [String], done: @escaping (String?) -> Void) {
        guard let key = Keychain.get() else { vlog("clean-up skipped: no API key"); done(nil); return }
        var user = text
        if !words.isEmpty { user = "Custom vocabulary: \(words.joined(separator: ", "))\n\nDictation:\n\(text)" }
        let payload: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let t0 = Date()
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var out: String?
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["stop_reason"] as? String == "refusal" {
                    vlog("clean-up refused")
                } else if let content = json["content"] as? [[String: Any]] {
                    let text = content.filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    out = text.isEmpty ? nil : text
                }
            } else {
                let body = data.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
                vlog("clean-up failed: status=\(status) \(err?.localizedDescription ?? body)")
            }
            vlog(String(format: "clean-up took %.0fms", Date().timeIntervalSince(t0) * 1000))
            DispatchQueue.main.async { done(out) }
        }.resume()
    }
}

// MARK: - Paste into frontmost app

enum Paster {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Restore the user's clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let saved else { return }
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = RecorderState()
    private lazy var panel = OverlayPanel(state: state)
    private let transcriber = Transcriber()
    private var recording = false
    private var monitors: [Any] = []
    private let defaults = UserDefaults.standard

    private let micMenu = NSMenu(), historyMenu = NSMenu(), keyMenu = NSMenu(), engineMenu = NSMenu(), cleanMenu = NSMenu()
    private let soundsItem = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
    private var wantsCleanup = false   // ⇧ was held during this recording

    private var customWords: [String] {
        (defaults.string(forKey: "customWords") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// "off", "shift" (hold ⇧ too) or "always".
    private var cleanupMode: String { defaults.string(forKey: "cleanup") ?? "shift" }
    private var soundsOn: Bool { defaults.object(forKey: "sounds") as? Bool ?? true }
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

    // Modifier keys that can be held for push-to-talk.
    private static let keys: [(code: UInt16, name: String, flag: NSEvent.ModifierFlags)] = [
        (61, "Right ⌥ Option", .option), (58, "Left ⌥ Option", .option),
        (54, "Right ⌘ Command", .command), (62, "Right ⌃ Control", .control),
        (60, "Right ⇧ Shift", .shift), (63, "fn", .function),
    ]
    private var pttKey: (code: UInt16, name: String, flag: NSEvent.ModifierFlags) {
        let code = defaults.object(forKey: "pttKey") as? Int ?? 61
        return Self.keys.first { $0.code == code } ?? Self.keys[0]
    }

    private static let modelsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VOIX/models")
    private func whisperModels() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.modelsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// nil = Apple on-device speech; otherwise the selected Whisper model.
    private var selectedModel: URL? {
        guard Transcriber.whisperCLI != nil, let name = defaults.string(forKey: "engine") else { return nil }
        return whisperModels().first { $0.lastPathComponent == name }
    }

    private var history: [String] {
        get { defaults.stringArray(forKey: "history") ?? [] }
        set { defaults.set(Array(newValue.prefix(10)), forKey: "history") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(hintItem)
        menu.addItem(.separator())
        for (title, sub) in [("History", historyMenu), ("Speech Engine", engineMenu), ("Clean Up with Claude", cleanMenu),
                             ("Push-to-Talk Key", keyMenu), ("Microphone", micMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            sub.delegate = self
            menu.addItem(item)
        }
        menu.addItem(withTitle: "Custom Words…", action: #selector(editWords), keyEquivalent: "")
        menu.addItem(.separator())
        soundsItem.action = #selector(toggleSounds)
        soundsItem.target = self
        menu.addItem(soundsItem)
        loginItem.action = #selector(toggleLogin)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAX), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit VOIX", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        transcriber.onLevel = { [weak self] rms in
            DispatchQueue.main.async { self?.push(level: rms) }
        }
        transcriber.onPartial = { [weak self] text in
            guard let self, self.recording else { return }
            self.state.partial = text
        }
        if let m = selectedModel { transcriber.server.ensure(model: m) }

        vlog("launch: ax=\(AXIsProcessTrusted()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) path=\(Bundle.main.bundlePath)")
        requestPermissions()
        installMonitorsWhenTrusted()
    }

    private func requestPermissions() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in vlog("mic access: \(ok)") }
        SFSpeechRecognizer.requestAuthorization { st in vlog("speech auth: \(st.rawValue)") }
    }

    /// A global key monitor added before Accessibility is granted never receives events,
    /// so wait for the grant and install it then — no relaunch needed.
    private func installMonitorsWhenTrusted() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.installMonitorsWhenTrusted() }
            return
        }
        vlog("accessibility trusted, installing key monitor")
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) { monitors.append(l) }
        // Esc while recording cancels.
        let esc: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53, self?.recording == true { self?.cancel() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { esc($0); return $0 }) { monitors.append(l) }
    }

    func applicationWillTerminate(_ note: Notification) {
        transcriber.server.stop()
    }

    private func handleFlags(_ e: NSEvent) {
        let key = pttKey
        if recording, key.flag != .shift, e.modifierFlags.contains(.shift) { wantsCleanup = true }
        guard e.keyCode == key.code else { return }
        let down = e.modifierFlags.contains(key.flag)
        if down && !recording { begin() } else if !down && recording { end() }
    }

    private func begin() {
        transcriber.whisperModel = selectedModel
        transcriber.customWords = customWords
        wantsCleanup = false
        do {
            try transcriber.start()
        } catch {
            vlog("engine start failed: \(error)")
            NSSound.beep()
            return
        }
        recording = true
        state.transcribing = false
        state.level = 0
        state.startedAt = Date()
        state.partial = ""
        state.status = ""
        play("Tink")
        setIcon(recording: true)
        panel.showBottomCenter()
    }

    private func end() {
        recording = false
        state.transcribing = true
        play("Pop")
        let clean = cleanupMode == "always" || (cleanupMode == "shift" && wantsCleanup)
        transcriber.stop { [weak self] text in
            guard let self else { return }
            vlog("transcript: \"\(text)\"")
            guard !text.isEmpty else { self.finish(nil); return }
            guard clean else { self.finish(text); return }
            self.state.status = "Cleaning up…"
            Cleaner.clean(text, words: self.customWords) { cleaned in self.finish(cleaned ?? text) }
        }
    }

    private func finish(_ text: String?) {
        panel.hide()
        setIcon(recording: false)
        state.status = ""
        guard let text, !text.isEmpty else { return }
        Paster.paste(text)
        history = [text] + history.filter { $0 != text }
    }

    private func cancel() {
        recording = false
        transcriber.cancel()
        play("Funk", volume: 0.15)
        panel.hide()
        setIcon(recording: false)
        vlog("cancelled")
    }

    private func play(_ name: String, volume: Float = 0.25) {
        guard soundsOn, let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }

    private func push(level rms: Float) {
        guard recording else { return }
        // Map RMS to 0...1 on a log scale so quiet speech still moves the bars.
        let db = 20 * log10(max(rms, 1e-6))
        let norm = CGFloat(min(max((db + 50) / 45, 0), 1))
        // Fast attack, slow release so the wave swells with speech and settles gently.
        let k: CGFloat = norm > state.level ? 0.6 : 0.15
        state.level += (norm - state.level) * k
    }

    private func setIcon(recording: Bool) {
        statusItem.button?.image = Self.menuBarGlyph(recording: recording)
    }

    /// Ring + waveform, matching the app icon. Template (auto light/dark) when idle, red while recording.
    static func menuBarGlyph(recording: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let color: NSColor = recording ? .systemRed : .black
            color.setStroke(); color.setFill()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
            let heights: [CGFloat] = [0.35, 0.7, 1.0, 0.6, 0.35]
            let w: CGFloat = 1.6, gap: CGFloat = 1.1
            var x = r.midX - (CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap) / 2
            for h in heights {
                let bh = 9 * h
                NSBezierPath(roundedRect: NSRect(x: x, y: r.midY - bh / 2, width: w, height: bh),
                             xRadius: w / 2, yRadius: w / 2).fill()
                x += w + gap
            }
            return true
        }
        img.isTemplate = !recording
        return img
    }

    // Menus are rebuilt each time they open so they always reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector?, _ value: Any?, on: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        switch menu {
        case micMenu:
            menu.removeAllItems()
            let current = AudioDevices.preferred()?.uid
            for d in AudioDevices.inputs() { add(d.name, #selector(pickMic(_:)), d.uid, on: d.uid == current) }
        case historyMenu:
            menu.removeAllItems()
            if history.isEmpty { add("No transcripts yet", nil, nil) }
            for t in history {
                add(t.count > 60 ? String(t.prefix(60)) + "…" : t, #selector(pasteHistory(_:)), t)
            }
        case keyMenu:
            menu.removeAllItems()
            for k in Self.keys { add(k.name, #selector(pickKey(_:)), Int(k.code), on: k.code == pttKey.code) }
        case cleanMenu:
            menu.removeAllItems()
            for (title, mode) in [("Off", "off"), ("When ⇧ Shift Is Also Held", "shift"), ("Always", "always")] {
                add(title, #selector(pickCleanup(_:)), mode, on: cleanupMode == mode)
            }
            menu.addItem(.separator())
            add(Keychain.get() == nil ? "Set Claude API Key…" : "Change Claude API Key…", #selector(setAPIKey), nil)
        case engineMenu:
            menu.removeAllItems()
            let current = selectedModel
            add("Apple On-Device (fastest)", #selector(pickEngine(_:)), nil, on: current == nil)
            if Transcriber.whisperCLI == nil {
                add("Whisper: run `brew install whisper-cpp`", nil, nil)
            } else {
                for m in whisperModels() {
                    let name = m.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
                    add("Whisper \(name)", #selector(pickEngine(_:)), m.lastPathComponent, on: m == current)
                }
            }
        default:
            hintItem.title = "Hold \(pttKey.name) to talk"
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            soundsItem.state = soundsOn ? .on : .off
        }
    }

    @objc private func pasteHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Give focus a moment to return to the previous app after the menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Paster.paste(text) }
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? Int, forKey: "pttKey")
    }

    @objc private func pickEngine(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String, forKey: "engine")
        if let m = selectedModel { transcriber.server.ensure(model: m) } else { transcriber.server.stop() }
    }

    @objc private func pickCleanup(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String, forKey: "cleanup")
    }

    @objc private func toggleSounds() {
        defaults.set(!soundsOn, forKey: "sounds")
    }

    /// Runs a small modal text prompt; returns nil on Cancel.
    private func prompt(_ title: String, _ info: String, value: String, secure: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func setAPIKey() {
        guard let key = prompt("Claude API Key", "Used only for “Clean Up with Claude”. Stored in your Keychain.",
                               value: "", secure: true) else { return }
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func editWords() {
        let current = defaults.string(forKey: "customWords") ?? ""
        guard let words = prompt("Custom Words", "Comma-separated names and terms to recognize, e.g. VOIX, Kubernetes, Supabase.",
                                 value: current, secure: false) else { return }
        defaults.set(words, forKey: "customWords")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            vlog("launch at login failed: \(error)")
        }
    }

    @objc private func pickMic(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "inputUID")
    }

    @objc private func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// --selftest <audiofile>: run the transcriber on a file and print text + latency after end-of-audio.
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else { print("SELFTEST speech auth: \(status.rawValue)"); exit(2) }
        DispatchQueue.main.async {
            let t = Transcriber()
            do {
                try t.start(useMic: false)
                let file = try AVAudioFile(forReading: url)
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buf)
                t.feed(buf)
            } catch { print("SELFTEST error: \(error)"); exit(1) }
            let t0 = Date()
            t.stop { text in
                print(String(format: "SELFTEST latency=%.0fms text=%@", Date().timeIntervalSince(t0) * 1000, text))
                exit(text.isEmpty ? 1 : 0)
            }
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
