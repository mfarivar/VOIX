import AVFoundation
import AudioToolbox
import CoreAudio
import Speech

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

    func start() throws {
        latest = ""
        finished = nil
        samples = []
        if whisperModel != nil { return try startMic() }
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
