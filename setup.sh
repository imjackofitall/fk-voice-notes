#!/bin/bash
# Fetches the Needle engine (macOS arm64 static lib) and the Whistle weights,
# then builds fk-voice-notes.app in Release.  Usage: ./setup.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")"

HF=https://huggingface.co
mkdir -p Vendor

fetch() {
  if [ -s "$2" ]; then echo "have $2"; return; fi
  echo "fetching $2"
  curl -fL --progress-bar "$1" -o "$2.part" && mv "$2.part" "$2"
}

fetch "$HF/Cactus-Compute/needle3/resolve/main/macos-arm64/libneedle.a" Vendor/libneedle.a
fetch "$HF/Cactus-Compute/needle3/resolve/main/macos-arm64/needle.h"    Vendor/needle.h
fetch "$HF/Cactus-Compute/whistle/resolve/main/whistle.cact"           Vendor/whistle.cact

[ "${1:-}" = "--no-build" ] && exit 0

xcodebuild -project fk-voice-notes.xcodeproj -target fk-voice-notes -configuration Release build -quiet
echo "built: $(pwd)/build/Release/fk-voice-notes.app"
