#!/bin/zsh
# Builds AirToggle.app.
#   ./build.sh             build for this Mac into ./build (signed with your local cert if present)
#   ./build.sh --install   build, install to ~/Applications, and launch
#   ./build.sh --release   build a universal (Apple silicon + Intel), ad-hoc-signed app and zip it into ./dist
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP=build/AirToggle.app
MODE="${1:-}"
FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ServiceManagement)
FLAGS=(-O -swift-version 5)

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$MODE" == "--release" ]]; then
  echo "Compiling universal binary (arm64 + x86_64)…"
  swiftc "${FLAGS[@]}" -target arm64-apple-macos14.0  "${FRAMEWORKS[@]}" -o build/AirToggle-arm64  Sources/main.swift
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos14.0 "${FRAMEWORKS[@]}" -o build/AirToggle-x86_64 Sources/main.swift
  lipo -create build/AirToggle-arm64 build/AirToggle-x86_64 -output "$APP/Contents/MacOS/AirToggle"
  rm build/AirToggle-arm64 build/AirToggle-x86_64
else
  echo "Compiling…"
  swiftc "${FLAGS[@]}" -target arm64-apple-macos14.0 "${FRAMEWORKS[@]}" -o "$APP/Contents/MacOS/AirToggle" Sources/main.swift
fi

cp Info.plist "$APP/Contents/Info.plist"

echo "Rendering icon…"
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -framework Cocoa -o build/make-icon Resources/make-icon.swift 2>/dev/null
build/make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/make-icon

if [[ "$MODE" == "--release" ]]; then
  # Ad-hoc signature: works on any Mac. A personal certificate would mean nothing on other machines.
  echo "Signing (ad hoc, for distribution)…"
  codesign --force --sign - --identifier dev.ben.AirToggle "$APP"
  mkdir -p dist
  ZIP="dist/AirToggle-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Release archive: $ZIP ($(du -h "$ZIP" | cut -f1))"
  lipo -info "$APP/Contents/MacOS/AirToggle"
  exit 0
fi

IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "AirToggle Local Signing"; then
  IDENTITY="AirToggle Local Signing"; echo "Signing with local certificate…"
else
  echo "Signing (ad hoc — run ./make-signing-cert.sh once to avoid re-granting Accessibility after rebuilds)…"
fi
codesign --force --sign "$IDENTITY" --identifier dev.ben.AirToggle "$APP"
echo "Built $APP (version $VERSION)"

if [[ "$MODE" == "--install" ]]; then
  DEST="$HOME/Applications/AirToggle.app"
  mkdir -p "$HOME/Applications"
  pkill -f "AirToggle.app/Contents/MacOS" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed to $DEST"
  open "$DEST"
  echo "Launched. Look for the ear icon in your menu bar."
fi
