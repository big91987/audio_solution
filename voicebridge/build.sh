#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="VoiceBridge.app"
ROOT_DIR="$(cd .. && pwd)"
OUT_DIR="$ROOT_DIR/output"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0")

mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/VoiceBridge" -framework Cocoa -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成: $(pwd)/$APP"

# ---- 打包成 DMG（拖进 /Applications 即可安装）----
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/VoiceBridge-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "VoiceBridge $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"

echo "DMG 已输出: $DMG"
ls -lh "$DMG"
