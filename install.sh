#!/bin/bash
# Downloads the latest WirePlay release, or installs a locally built app with --local PATH.
#   curl -fsSL https://raw.githubusercontent.com/ben-medpro/WirePlay/main/install.sh | bash
set -euo pipefail

wireplay_verify_app() {
  [[ -d "$1" && ! -L "$1" && -x "$1/Contents/MacOS/WirePlay" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "dev.ben.WirePlay" ]] || return 1
  codesign --verify --deep --strict --all-architectures "$1"
}

wireplay_quit_running() {
  if pgrep -x WirePlay >/dev/null; then
    # Give the app its normal shutdown path; never force-kill an active presentation.
    osascript -e 'with timeout of 10 seconds' \
      -e 'tell application id "dev.ben.WirePlay" to quit' -e 'end timeout' || return 1
    for ((attempt=0; attempt<20; attempt++)); do
      if ! pgrep -x WirePlay >/dev/null; then return 0; fi
      sleep 0.25
    done
    echo "WirePlay is still running. Stop its presentation and quit it before installing."
    return 1
  fi
}

# Kept as a function so failure-injection checks exercise this exact replacement path.
wireplay_replace_app() (
  SOURCE_APP="$1"
  DEST_APP="$2"
  WORK=$(mktemp -d "${DEST_APP%/*}/.WirePlay-install.XXXXXX") || exit 1
  BACKUP="$WORK/previous-WirePlay.app"
  trap 'if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
          echo "Previous app preserved at: $BACKUP"
        else
          rm -rf "$WORK"
        fi' EXIT

  # Copy beside the destination for same-volume renames. Discard sync-folder metadata
  # before checking the signature, while the installed app is still untouched.
  ditto --norsrc --noextattr "$SOURCE_APP" "$WORK/WirePlay.app" || exit 1
  if ! wireplay_verify_app "$WORK/WirePlay.app"; then
    echo "The staged app failed verification. Your installed app was not changed."
    exit 1
  fi
  wireplay_quit_running || exit 1
  if [[ -e "$DEST_APP" || -L "$DEST_APP" ]]; then
    mv "$DEST_APP" "$BACKUP" || exit 1
  fi
  if ! mv "$WORK/WirePlay.app" "$DEST_APP" || ! wireplay_verify_app "$DEST_APP"; then
    echo "The replacement failed. Restoring the previous app."
    if [[ -e "$DEST_APP" || -L "$DEST_APP" ]]; then
      mv "$DEST_APP" "$WORK/rejected-WirePlay.app" || exit 1
    fi
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
      if ! mv "$BACKUP" "$DEST_APP"; then
        echo "Automatic restore failed. Keep the backup shown below for manual recovery."
        exit 1
      fi
      echo "Your previous WirePlay was restored."
    fi
    exit 1
  fi
  echo "Installed app signature verified."
)

# Tests source only the functions; normal execution continues below.
if [[ "${BASH_SOURCE[0]:-}" != "$0" && -n "${BASH_SOURCE[0]:-}" ]]; then return 0; fi

REPO="ben-medpro/WirePlay"
DEST="/Applications/WirePlay.app"
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 26 )); then
  echo "WirePlay needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."; exit 1
fi

if [[ "${1:-}" == "--local" && $# == 2 ]]; then
  NEW_APP="$2"
elif (( $# == 0 )); then
  echo "Looking up the latest WirePlay release…"
  # Releases are regular releases (with beta in the tag), so this endpoint is deterministic.
  RELEASE=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
  ASSETS=$(printf '%s\n' "$RELEASE" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' || true)
  URL=$(printf '%s\n' "$ASSETS" | grep '\.zip$' | head -1 || true)
  SUM_URL=$(printf '%s\n' "$ASSETS" | grep -Fx "$URL.sha256" || true)
  if [[ -z "$URL" || -z "$SUM_URL" ]]; then
    echo "No release archive with a matching checksum was found. Visit https://github.com/$REPO/releases"; exit 1
  fi
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "Downloading $(basename "$URL")…"
  curl -fsSL "$URL" -o "$TMP/WirePlay.zip"
  EXPECTED=$(curl -fsSL "$SUM_URL" | awk '{print tolower($1)}')
  ACTUAL=$(shasum -a 256 "$TMP/WirePlay.zip" | awk '{print $1}')
  if [[ ! "$EXPECTED" =~ ^[[:xdigit:]]{64}$ || "$EXPECTED" != "$ACTUAL" ]]; then
    echo "The checksum is missing, invalid, or does not match. Nothing was installed."; exit 1
  fi
  echo "Checksum verified."
  ditto -x -k "$TMP/WirePlay.zip" "$TMP/unpacked"
  NEW_APP="$TMP/unpacked/WirePlay.app"
else
  echo "Usage: install.sh [--local /path/to/WirePlay.app]"; exit 1
fi

[[ -d "$NEW_APP" && ! -L "$NEW_APP" ]] || { echo "WirePlay.app was not found."; exit 1; }
echo "Installing to ${DEST}…"
wireplay_replace_app "$NEW_APP" "$DEST"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
OLD="$HOME/Applications/WirePlay.app"
if [[ -d "$OLD" ]]; then
  # Keep legacy copies recoverable, too; only remove their registration after success.
  OLD_BACKUP=$(mktemp -d "$HOME/Applications/.WirePlay-previous.XXXXXX")
  pluginkit -r "$OLD/Contents/PlugIns/WirePlayControls.appex" 2>/dev/null || true
  "$LSREGISTER" -u "$OLD" 2>/dev/null || true
  if mv "$OLD" "$OLD_BACKUP/WirePlay.app"; then
    echo "Legacy copy preserved at: $OLD_BACKUP/WirePlay.app"
  else
    echo "The legacy copy could not be moved and remains at: $OLD"
  fi
fi
"$LSREGISTER" -f "$DEST" 2>/dev/null || true
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
