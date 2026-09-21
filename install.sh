#!/bin/bash
# AirToggle installer — downloads the latest release, installs it to /Applications, and opens it.
#   curl -fsSL https://raw.githubusercontent.com/ben-medpro/AirToggle/main/install.sh | bash
set -euo pipefail

REPO="ben-medpro/AirToggle"
DEST="/Applications/AirToggle.app"

echo "Looking up the latest AirToggle release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(http[^"]*\)"/\1/')
if [[ -z "$URL" ]]; then echo "Could not find a release download. Visit https://github.com/$REPO/releases"; exit 1; fi

TMP=$(mktemp -d)
echo "Downloading $(basename "$URL")…"
curl -fsSL "$URL" -o "$TMP/AirToggle.zip"
ditto -x -k "$TMP/AirToggle.zip" "$TMP/unpacked"

echo "Installing to $DEST…"
pkill -f "AirToggle.app/Contents/MacOS" 2>/dev/null || true
rm -rf "$DEST"
mv "$TMP/unpacked/AirToggle.app" "$DEST"
rm -rf "$TMP"

# The app is open source and not notarized (that needs a paid Apple Developer account), so
# macOS marks the download as quarantined and would refuse to open it. Clearing that flag is
# equivalent to right-clicking the app and choosing Open.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
cat <<'MSG'

AirToggle is installed and running.
  • Grant the one permission it asks for (System Settings › Privacy & Security › Accessibility).
  • Press ⌃⌥A to toggle your AirPods. Click the ear icon in the menu bar for settings.
MSG
