# Changelog

All notable changes to VOIX are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-25

First public release.

### Added
- Push-to-talk dictation from the menu bar: hold a modifier key, speak, release to paste.
- Recording overlay with live waveform, timer and live caption.
- Apple on-device speech recognition (default).
- Optional local Whisper engines (whisper.cpp `base.en`, `small.en`), kept warm in the background.
- Optional "Clean Up with Claude" to tidy dictation into a clean prompt; API key stored in the Keychain.
- Custom words, transcript history, Esc to cancel, microphone picker, configurable push-to-talk key.
- Launch at login and optional start/stop sounds.
- Universal binary (Apple silicon and Intel), macOS 13 or later.

[1.0.0]: https://github.com/mfarivar/VOIX/releases/tag/v1.0.0
