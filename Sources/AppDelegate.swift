import AppKit
import AVFoundation
import ServiceManagement
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = RecorderState()
    private lazy var panel = OverlayPanel(state: state)
    private let transcriber = Transcriber()
    private var recording = false
    private var monitors: [Any] = []
    private var sigterm: DispatchSourceSignal?
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
        trimLog()
        migrateSettings()
        // Quit cleanly on SIGTERM (logout, `kill`) so the Whisper server is shut down too.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
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

    /// Carries settings over from pre-1.0 builds, which used the bundle ID "local.voix".
    private func migrateSettings() {
        guard !defaults.bool(forKey: "migrated"), let old = UserDefaults(suiteName: "local.voix") else { return }
        for key in ["pttKey", "engine", "inputUID", "history", "customWords", "cleanup", "sounds", "locale"] {
            if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
        }
        defaults.set(true, forKey: "migrated")
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
            vlog("transcribed \(text.count) chars")
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
