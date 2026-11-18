#!/bin/bash
# Compila Recuperador 3.0 y crea el instalador Recuperador-3.0.dmg con fondo moradito.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

./scripts/build-app.sh

APP="build/Recuperador.app"
if [ ! -d "$APP" ] && [ -d "build/Recuperador-nuevo.app" ]; then
    APP="build/Recuperador-nuevo.app"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Recuperador/Info.plist 2>/dev/null || echo "3.2.1")
VOL_NAME="Recuperador $VERSION"
DMG_FINAL="${1:-Recuperador-$VERSION.dmg}"
DMG_RW="build/Recuperador-rw.dmg"
STAGE="build/dmg-stage"

# Desmontar cualquier montaje previo con el mismo nombre
if [ -d "/Volumes/$VOL_NAME" ]; then
    hdiutil detach "/Volumes/$VOL_NAME" -force >/dev/null 2>&1 || true
fi

rm -rf "$STAGE" "$DMG_RW" "$DMG_FINAL"
mkdir -p "$STAGE/.background"
mkdir -p "$(dirname "$DMG_FINAL")"

cp -R "$APP" "$STAGE/Recuperador.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-bg.swift "$STAGE/.background/bg.tiff" "$VERSION"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
SetFile -a C "$STAGE" 2>/dev/null || true

hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDRW "$DMG_RW" >/dev/null

MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_RW" | awk -F'\t' '/\/Volumes\// {print $3; exit}')

if [ -n "$MOUNT_DIR" ]; then
    SetFile -a V "$MOUNT_DIR/.background" 2>/dev/null || true
    SetFile -a V "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
    SetFile -a C "$MOUNT_DIR" 2>/dev/null || true

    # Si Finder está disponible, posiciona los íconos y aplica el fondo moradito
    osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {220, 180, 860, 600}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 13
        set background picture of opts to file ".background:bg.tiff"
        set position of item "Recuperador.app" of container window to {180, 210}
        set position of item "Applications" of container window to {460, 210}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
    sync
    hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
fi

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -rf "$STAGE" "$DMG_RW" "build/Recuperador-nuevo.app"
case "$DMG_FINAL" in
    /*) echo "DMG listo: $DMG_FINAL" ;;
    *)  echo "DMG listo: $PWD/$DMG_FINAL" ;;
esac
