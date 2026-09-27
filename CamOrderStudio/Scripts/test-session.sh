#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.build/au"
arch="$(uname -m)"
mkdir -p "$root/.build/au-tests"
xcrun clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=13.0 -I"$root/AudioUnit" "$root/Tests/AudioUnit/SessionTestHost.mm" -c -o "$root/.build/au-tests/session-host.o"
ui=()
for file in "$root"/Sources/CamOrderStudioApp/*.swift; do
  if [[ "$(basename "$file")" != CamOrderStudioApp.swift ]]; then ui+=("$file"); fi
done
xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos13.0" -parse-as-library \
  -import-objc-header "$root/Tests/AudioUnit/SessionTestHost.h" -I"$root/AudioUnit" -I"$build" -L"$build" -lCamOrderStudioCore \
  "${ui[@]}" "$root/AudioUnit/PluginSession.swift" "$root/Tests/AudioUnit/SessionIntegration.swift" "$root/Tests/AudioUnit/EditingIntegration.swift" "$root/Tests/AudioUnit/MultiInputIntegration.swift" "$root/Tests/AudioUnit/EditorInteractionIntegration.swift" \
  "$build"/*-"$arch".o "$root/.build/au-tests/session-host.o" \
  -Xlinker -lc++ -framework AppKit -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreMIDI -framework AVFoundation -framework CoreMediaIO \
  -o "$root/.build/au-tests/session-integration"
CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS=1 "$root/.build/au-tests/session-integration" "$root/.build/au-tests/editor-canvas.png"
