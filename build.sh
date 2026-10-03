#!/bin/sh
# Builds Headroom.app next to this script. Run it with: open Headroom.app
set -e
cd "$(dirname "$0")"

APP=Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>dev.julio.headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" Headroom.swift -o "$APP/Contents/MacOS/Headroom"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
