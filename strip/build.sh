#!/bin/bash
# Builds the strip app. The networking layer in ../shared is the same code the To Reply
# iPhone app uses, so the strip can't drift from the server's API.
set -euo pipefail
cd "$(dirname "$0")"

TOREPLY_SHARED="${TOREPLY_SHARED:-../shared}"
APP=build/Photosynthesizing.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    -o "$APP/Contents/MacOS/Photosynthesizing" \
    app/*.swift "$TOREPLY_SHARED"/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.alexa.claudetv</string>
    <key>CFBundleName</key><string>Photosynthesizing</string>
    <key>CFBundleDisplayName</key><string>Photosynthesizing</string>
    <key>CFBundleExecutable</key><string>Photosynthesizing</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.alexa.claudetv</string>
        <key>CFBundleURLSchemes</key><array><string>claudetv</string></array>
    </dict></array>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
