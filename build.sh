#!/bin/sh
# Builds build/Palette Ring.app
set -e
cd "$(dirname "$0")"
APP="build/Palette Ring.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/PaletteRing"
codesign --force --sign - "$APP"
echo "Built $APP"
