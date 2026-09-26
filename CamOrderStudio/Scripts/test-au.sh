#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.build/au-tests"
xcrun clang++ -std=c++17 -fobjc-arc -I"$root/AudioUnit" "$root/Tests/AudioUnit/AUIntegration.mm" \
  -framework AppKit -framework AudioUnit -framework AudioToolbox -o "$root/.build/au-tests/integration"
CAMORDER_DISABLE_AUTOPREVIEW_FOR_TESTS=1 "$root/.build/au-tests/integration" "$root/dist/CamOrder Studio.component" "$root/.build/au-tests/editor.png"
