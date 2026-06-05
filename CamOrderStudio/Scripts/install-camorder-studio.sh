#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CamOrder Studio"
EXECUTABLE_NAME="CamOrderStudio"
BUNDLE_ID="com.santismo.CamOrderStudio"
BUILD_DIR="$ROOT_DIR/.build/release"
STAGING_DIR="$ROOT_DIR/.build/app-bundle"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
ICONSET="$ROOT_DIR/.build/CamOrderStudio.iconset"
ICON_PNG="$ROOT_DIR/.build/camorder-studio-icon-1024.png"
ICON_FILE="$ROOT_DIR/.build/AppIcon.icns"
ICON_SWIFT="$ROOT_DIR/.build/GenerateCamOrderStudioIcon.swift"

cd "$ROOT_DIR"

swift build -c release --product "$EXECUTABLE_NAME"

rm -rf "$STAGING_DIR" "$ICONSET" "$ICON_PNG" "$ICON_FILE" "$ICON_SWIFT"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$ICONSET"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSCameraUsageDescription</key>
  <string>CamOrder Studio records video takes from your selected camera.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>CamOrder Studio may capture camera audio when that export option is enabled.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>CamOrder Studio records the screen or Logic Pro window when selected as a video source.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

cat > "$ICON_SWIFT" <<'SWIFT'
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
NSColor.clear.setFill()
rect.fill()

let inset: CGFloat = 58
let rounded = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 190, yRadius: 190)
NSGraphicsContext.saveGraphicsState()
rounded.addClip()
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.19, alpha: 1),
    NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.06, alpha: 1)
])!
background.draw(in: rect.insetBy(dx: inset, dy: inset), angle: 90)
NSGraphicsContext.restoreGraphicsState()

NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
rounded.fill()
NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
rounded.lineWidth = 8
rounded.stroke()

let emoji = "📹" as NSString
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 610),
    .paragraphStyle: paragraph
]
let textRect = NSRect(x: 0, y: 190, width: 1024, height: 660)
emoji.draw(in: textRect, withAttributes: attributes)

image.unlockFocus()

guard
    let data = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: data),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render app icon")
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$ICON_SWIFT" "$ICON_PNG"

for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size="${entry%% *}"
  name="${entry#* }"
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/$name" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICON_FILE"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '\"' '/Apple Development/ { print $2; exit }')"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null
else
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
  echo "Cannot write to $INSTALL_DIR. Run this script from an admin account or install manually from:"
  echo "$APP_BUNDLE"
  exit 1
fi

rm -rf "$INSTALLED_APP"
cp -R "$APP_BUNDLE" "$INSTALLED_APP"
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
touch "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signed with: $SIGNING_IDENTITY"
fi
echo "Open it with:"
echo "open '$INSTALLED_APP'"
