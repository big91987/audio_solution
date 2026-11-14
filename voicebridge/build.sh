#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="VoiceBridge.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/VoiceBridge" -framework Cocoa -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "构建完成: $(pwd)/$APP"
