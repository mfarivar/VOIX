#!/bin/zsh
# Optional: installs Whisper (whisper.cpp via Homebrew) and the English models VOIX uses.
set -e
if ! command -v brew >/dev/null; then
  echo "Homebrew is required: https://brew.sh"; read -k1 "?Press any key to close"; exit 1
fi
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
M="$HOME/Library/Application Support/VOIX/models"
mkdir -p "$M"
for m in base.en small.en; do
  [ -f "$M/ggml-$m.bin" ] && continue
  echo "Downloading $m model…"
  curl -L --fail --progress-bar -o "$M/ggml-$m.bin.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin"
  mv "$M/ggml-$m.bin.part" "$M/ggml-$m.bin"
done
echo "Done. Pick a Whisper model under VOIX → Speech Engine."
read -k1 "?Press any key to close"
