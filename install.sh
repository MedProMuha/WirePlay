#!/bin/bash
# WirePlay installer — downloads the latest release, installs it to /Applications, and opens it.
#   curl -fsSL https://raw.githubusercontent.com/ben-medpro/WirePlay/main/install.sh | bash
set -euo pipefail

REPO="ben-medpro/WirePlay"
DEST="/Applications/WirePlay.app"

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 26 )); then
  echo "WirePlay needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."; exit 1
fi

echo "Looking up the latest WirePlay release…"
# Releases are published as regular releases (with "beta" in the tag) so this endpoint is deterministic.
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(http[^"]*\)"/\1/')
if [[ -z "$URL" ]]; then echo "Could not find a release download. Visit https://github.com/$REPO/releases"; exit 1; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $(basename "$URL")…"
curl -fsSL "$URL" -o "$TMP/WirePlay.zip"
ditto -x -k "$TMP/WirePlay.zip" "$TMP/unpacked"
NEW_APP="$TMP/unpacked/WirePlay.app"
if [[ ! -d "$NEW_APP" ]]; then echo "The download didn't contain WirePlay.app. Visit https://github.com/$REPO/releases"; exit 1; fi

# Braces matter: macOS's Bash 3.2 reads the "…" after a bare $DEST as part of the variable name.
echo "Installing to ${DEST}…"
pkill -f "WirePlay.app/Contents/MacOS" 2>/dev/null || true
# Keep the current copy until the new one is in place, so a failed install doesn't leave nothing.
BACKUP=""
if [[ -e "$DEST" ]]; then
  BACKUP="$TMP/previous-WirePlay.app"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$NEW_APP" "$DEST"; then
  if [[ -n "$BACKUP" ]]; then mv "$BACKUP" "$DEST"; echo "Install failed. Your previous WirePlay was put back."; fi
  exit 1
fi

# The app is open source and not notarized (that needs a paid Apple Developer account), so
# macOS marks the download as quarantined and would refuse to open it. Clearing that flag is
# equivalent to right-clicking the app and choosing Open.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Register the app and its Control Center button with macOS.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true
pluginkit -a "$DEST/Contents/PlugIns/WirePlayControls.appex" 2>/dev/null || true

open "$DEST"
cat <<'MSG'

WirePlay is installed and running (monitor-and-plug icon in the menu bar).
  • Plug in an HDMI / USB-C display: WirePlay asks what to show on it.
  • The first time you pick "Window or App", allow Screen Recording when asked
    (System Settings › Privacy & Security › Screen & System Audio Recording).
  • Optional: add the WirePlay button to Control Center (Control Center › Edit Controls).
  • Settings: click the menu bar icon › Settings…
MSG
