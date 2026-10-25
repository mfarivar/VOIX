<p align="center"><img src="Resources/icon_1024.png" width="128" alt="VOIX icon"></p>

<h1 align="center">VOIX</h1>

<p align="center"><b>Fast push-to-talk dictation for macOS.</b><br>
Hold a key, speak, release — your words are typed into whatever app you're in.</p>

---

VOIX lives in the menu bar. Hold **Right ⌥ Option**, and a small recording pill slides up at the bottom of the screen with a live waveform and your words appearing as you speak. Release the key and the text is pasted into the focused field, usually within a fraction of a second. Your clipboard is restored afterwards.

It was built as a lightweight, fast alternative for dictating prompts to AI tools, but works anywhere you can type.

## Features

- **Push-to-talk** — hold a modifier key (Right ⌥ by default; Left ⌥, Right ⌘, Right ⌃, Right ⇧ or fn) to record.
- **Instant, private transcription** — Apple's on-device speech recognition by default; nothing leaves your Mac.
- **Optional Whisper engines** — local [whisper.cpp](https://github.com/ggerganov/whisper.cpp) `base.en` / `small.en`, kept warm in the background (~0.3 s per clip on an M2).
- **Live caption** — see the transcript form above the recording pill while you talk.
- **Clean up with Claude** — hold ⇧ Shift too (or turn it on always) to strip filler words and tidy the text into a clean prompt before it's pasted.
- **Custom words** — teach it names and jargon it keeps getting wrong.
- **Esc to cancel** — discard a recording while still holding the key.
- **History** — re-paste any of your last 10 transcripts from the menu.
- **Mic picker** — records from your built-in mic even if the system input points at a virtual device.
- Launch at login, optional start/stop sounds, universal binary (Apple silicon + Intel), macOS 13+.

## Install

Download `VOIX.dmg` (or build it — see below), open it and drag **VOIX** into **Applications**.

1. On first launch, macOS may say it can't verify the developer (the app is self-signed). Go to **System Settings → Privacy & Security → Open Anyway**.
2. Allow **Microphone** and **Speech Recognition**, and turn VOIX on under **Privacy & Security → Accessibility** (needed to detect the key and paste).
3. Hold **Right ⌥**, speak, release.

**Whisper (optional):** double-click `Install Whisper.command` from the DMG. It installs `whisper-cpp` via Homebrew and downloads the English models (~640 MB) to `~/Library/Application Support/VOIX/models`. Then pick a model under **Speech Engine**.

**Clean-up (optional):** menu → **Clean Up with Claude → Set Claude API Key…**. The key is stored in your Keychain.

## Build from source

Requires Xcode command-line tools (Swift 5.9+).

```sh
./Tools/make_cert.sh   # once: local signing cert so macOS permissions survive rebuilds
./build.sh             # -> build/VOIX.app
./package.sh           # -> build/VOIX.dmg (drag-to-install disk image)
```

The whole app is a single file, `Sources/main.swift` (AppKit + SwiftUI, AVAudioEngine, Speech, CoreAudio). `Tools/make_icon.swift` renders the app icon.

## Troubleshooting

- **Nothing happens when holding the key** — check VOIX is enabled under Accessibility. If you rebuilt with ad-hoc signing, remove VOIX from the list and add it again.
- **"No speech detected"** — pick your real microphone under **Microphone** in the VOIX menu.
- Logs are written to `~/Library/Logs/VOIX.log`.
