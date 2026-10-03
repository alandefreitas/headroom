#!/bin/sh
# Builds Headroom.app next to this script. Run it with: open Headroom.app
#
#   ./build.sh                      native build for this Mac
#   UNIVERSAL=1 VERSION=0.1.0 ./build.sh   Apple Silicon + Intel, for releases
set -e
cd "$(dirname "$0")"

APP=Headroom.app
VERSION=${VERSION:-dev}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>dev.julio.headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

BIN="$APP/Contents/MacOS/Headroom"
FLAGS="-O -swift-version 5 -parse-as-library"
if [ -n "$UNIVERSAL" ]; then
  TMP=$(mktemp -d)
  swiftc $FLAGS -target arm64-apple-macos14.0 Headroom.swift -o "$TMP/arm64"
  swiftc $FLAGS -target x86_64-apple-macos14.0 Headroom.swift -o "$TMP/x86_64"
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
  rm -rf "$TMP"
else
  swiftc $FLAGS -target "$(uname -m)-apple-macos14.0" Headroom.swift -o "$BIN"
fi
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP ($VERSION)"
