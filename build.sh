#!/bin/zsh
# Builds WirePlay.app.
#   ./build.sh             build for this Mac into ./build (signed with your local cert if present)
#   ./build.sh --install   build, install to /Applications, and launch
#   ./build.sh --release   build a universal (Apple silicon + Intel), ad-hoc-signed app and zip it into ./dist
set -euo pipefail
cd "$(dirname "$0")"

# OneDrive (and similar sync folders) keeps re-adding Finder metadata to files, which breaks the
# code signature of anything we ship. Release builds therefore run in a temporary copy.
# The git commit is stamped into the app (Info.plist WirePlayCommit), so you can tell exactly
# which source a copy was built from. "-dirty" means there were uncommitted changes.
if [[ -z "${WIREPLAY_COMMIT:-}" ]]; then
  WIREPLAY_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  git diff --quiet HEAD -- 2>/dev/null || WIREPLAY_COMMIT="$WIREPLAY_COMMIT-dirty"
  export WIREPLAY_COMMIT
fi

if [[ "${1:-}" == "--release" && -z "${WIREPLAY_CLEAN_BUILD:-}" ]]; then
  WORK=$(mktemp -d)
  rsync -a --exclude build --exclude dist --exclude .git ./ "$WORK/src/"
  WIREPLAY_CLEAN_BUILD=1 "$WORK/src/build.sh" --release
  mkdir -p dist && cp "$WORK/src/dist/"*.zip "$WORK/src/dist/"*.sha256 dist/
  rm -rf "$WORK"
  echo "Copied to $PWD/dist/"
  exit 0
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
APP=build/WirePlay.app
MODE="${1:-}"
FRAMEWORKS=(-framework Cocoa -framework SwiftUI -framework ScreenCaptureKit -framework CoreMedia -framework ServiceManagement)
FLAGS=(-O -swift-version 5)

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Xcode is needed for the Control Center button (an app extension). Use it without requiring
# `sudo xcode-select`; without Xcode the app still builds, just without the button.
if [[ -d /Applications/Xcode.app ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi

if [[ "$MODE" == "--release" ]]; then
  echo "Compiling universal binary (arm64 + x86_64)…"
  swiftc "${FLAGS[@]}" -target arm64-apple-macos26.0  "${FRAMEWORKS[@]}" -o build/WirePlay-arm64  Sources/main.swift
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos26.0 "${FRAMEWORKS[@]}" -o build/WirePlay-x86_64 Sources/main.swift
  lipo -create build/WirePlay-arm64 build/WirePlay-x86_64 -output "$APP/Contents/MacOS/WirePlay"
  rm build/WirePlay-arm64 build/WirePlay-x86_64
  ARCHS=(-arch arm64 -arch x86_64)
else
  # Build for this Mac's own architecture (arm64 on Apple silicon, x86_64 on Intel).
  LOCAL_ARCH=$(uname -m)
  echo "Compiling ($LOCAL_ARCH)…"
  swiftc "${FLAGS[@]}" -target "$LOCAL_ARCH-apple-macos26.0" "${FRAMEWORKS[@]}" -o "$APP/Contents/MacOS/WirePlay" Sources/main.swift
  ARCHS=(-arch "$LOCAL_ARCH")
fi
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :WirePlayCommit string $WIREPLAY_COMMIT" "$APP/Contents/Info.plist"

echo "Rendering icon…"
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/WirePlay" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Release builds are ad hoc (a personal certificate means nothing on other Macs). Local builds
# reuse the local signing cert (made for AirToggle) so macOS keeps recognising the app, and its
# Screen Recording / Accessibility permissions, across rebuilds.
IDENTITY="-"
if [[ "$MODE" != "--release" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "AirToggle Local Signing"; then
  IDENTITY="AirToggle Local Signing"
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "Building Control Center button…"
  xcodebuild -quiet -project WirePlayControls.xcodeproj -target WirePlayControls -configuration Release "${ARCHS[@]}" \
    ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/build/xcode" OBJROOT="$PWD/build/xcode/obj" 2>&1 | grep -v "^$" || true
  APPEX=build/xcode/Release/WirePlayControls.appex
  [[ -d "$APPEX" ]] || { echo "Control Center button failed to build"; exit 1; }
  cp -R "$APPEX" "$APP/Contents/PlugIns/"
  # The button always carries the app's version. Its build number must keep going up, or
  # Control Center keeps showing a cached copy of the old button.
  APPEX_PLIST="$APP/Contents/PlugIns/WirePlayControls.appex/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX_PLIST"
  xattr -cr "$APP" # OneDrive adds Finder metadata that code signing rejects
  # Extensions must be sandboxed; sign the extension first, then the app around it.
  codesign --force --sign "$IDENTITY" --identifier dev.ben.WirePlay.Controls \
    --entitlements Controls/WirePlayControls.entitlements "$APP/Contents/PlugIns/WirePlayControls.appex"
elif [[ "$MODE" == "--release" ]]; then
  echo "A release needs Xcode (for the Control Center button)."; exit 1
else
  echo "Xcode not found: skipping the Control Center button."
fi

xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier dev.ben.WirePlay "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, commit $WIREPLAY_COMMIT)"

if [[ "$MODE" == "--release" ]]; then
  mkdir -p dist
  ZIP="dist/WirePlay-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  # Check the signature the way a tester will receive it: freshly unzipped.
  CHECK=$(mktemp -d); ditto -x -k "$ZIP" "$CHECK"
  # On its own line so a failed check stops the script (set -e ignores a failure left of &&).
  codesign --verify --deep --strict "$CHECK/WirePlay.app"
  echo "Signature verified on the unzipped app"
  rm -rf "$CHECK"
  # Published next to the zip; install.sh refuses a download that doesn't match.
  (cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "Release archive: $ZIP ($(du -h "$ZIP" | cut -f1)), SHA-256 $(cut -d' ' -f1 "$ZIP.sha256")"
  lipo -info "$APP/Contents/MacOS/WirePlay" "$APP/Contents/PlugIns/WirePlayControls.appex/Contents/MacOS/WirePlayControls"
  exit 0
fi

if [[ "$MODE" == "--install" ]]; then
  # Same place install.sh uses, so there is only ever one copy (and one Control Center button).
  DEST="/Applications/WirePlay.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pkill -f "WirePlay.app/Contents/MacOS" 2>/dev/null || true
  OLD="$HOME/Applications/WirePlay.app" # where earlier builds were installed
  if [[ -d "$OLD" ]]; then
    pluginkit -r "$OLD/Contents/PlugIns/WirePlayControls.appex" 2>/dev/null || true
    "$LSREGISTER" -u "$OLD" 2>/dev/null || true
    rm -rf "$OLD"
    echo "Removed the older copy in ~/Applications."
  fi
  rm -rf "$DEST" && cp -R "$APP" "$DEST"
  # Register the app and its Control Center button with macOS.
  "$LSREGISTER" -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/WirePlayControls.appex" 2>/dev/null || true
  open "$DEST"
  echo "Installed and launched $DEST — look for the monitor-and-plug icon in the menu bar."
fi
