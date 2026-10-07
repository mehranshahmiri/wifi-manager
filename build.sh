#!/bin/sh
# Builds "Wi-Fi Manager.app" next to this script. Usage: ./build.sh [install]
set -e
cd "$(dirname "$0")"
APP="Wi-Fi Manager.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macos12.0" -o "$APP/Contents/MacOS/WifiManager" WifiManager.swift
codesign --force --deep -s - "$APP"
[ "$1" = install ] && cp -R "$APP" /Applications/ && echo "Installed to /Applications"
echo "Built $APP"
