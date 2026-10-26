#!/bin/bash
# Compila y empaqueta Recuperador.app en build/
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product Recuperador
APP=build/Recuperador.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Recuperador "$APP/Contents/MacOS/"

swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp Sources/Recuperador/Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "Listo: $APP"
