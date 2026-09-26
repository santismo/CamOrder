#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.build/au"
component="$root/dist/CamOrder Studio.component"
mkdir -p "$build" "$component/Contents/MacOS" "$component/Contents/Resources"
sdk="$root/Vendor/AudioUnitSDK"
arch="${CAMORDER_ARCH:-$(uname -m)}"
target="$arch-apple-macos13.0"
objects=()
for file in "$sdk"/src/AudioUnitSDK/*.cpp; do
  object="$build/$(basename "$file" .cpp)-$arch.o"
  if [[ ! -f "$object" || "$file" -nt "$object" ]]; then
    xcrun clang++ -std=c++23 -O2 -fvisibility=hidden -arch "$arch" -mmacosx-version-min=13.0 -I"$sdk/include" -c "$file" -o "$object"
  fi
  objects+=("$object")
done
xcrun clang++ -std=c++23 -O2 -fobjc-arc -arch "$arch" -mmacosx-version-min=13.0 -I"$sdk/include" -c "$root/AudioUnit/CamOrderAU.mm" -o "$build/CamOrderAU-$arch.o"
xcrun swiftc -swift-version 5 -O -target "$target" -parse-as-library -emit-module -emit-library -static -module-name CamOrderStudioCore \
  "$root"/Sources/CamOrderStudioCore/*.swift -emit-module-path "$build/CamOrderStudioCore.swiftmodule" -o "$build/libCamOrderStudioCore.a"
ui=()
for file in "$root"/Sources/CamOrderStudioApp/*.swift; do
  if [[ "$(basename "$file")" != CamOrderStudioApp.swift ]]; then ui+=("$file"); fi
done
xcrun swiftc -swift-version 5 -O -target "$target" -parse-as-library -emit-library -module-name CamOrderStudioPlugin \
  -import-objc-header "$root/AudioUnit/CamOrderBridge.h" -I"$build" -L"$build" -lCamOrderStudioCore \
  "${ui[@]}" "$root/AudioUnit/PluginSession.swift" "$build/CamOrderAU-$arch.o" "${objects[@]}" \
  -Xlinker -install_name -Xlinker @rpath/CamOrderStudioAU -Xlinker -lc++ -framework AppKit -framework AudioToolbox -framework AudioUnit -framework CoreAudio -framework CoreMIDI -framework AVFoundation -framework CoreMediaIO \
  -o "$component/Contents/MacOS/CamOrderStudioAU"
helper="$component/Contents/Resources/CamOrder Capture.app"
mkdir -p "$helper/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$target" -I"$build" -L"$build" -lCamOrderStudioCore \
  "$root/CaptureHelper/main.swift" -o "$helper/Contents/MacOS/CamOrderCapture"
python3 "$root/Scripts/write-helper-plist.py" "$helper/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$helper"
python3 "$root/Scripts/write-au-plist.py" "$component/Contents/Info.plist"
# Ad-hoc signing is appropriate for a local development build.
codesign --force --sign - --timestamp=none "$component"
echo "Built: $component"
