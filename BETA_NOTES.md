# Beta Tester Muha -- Notes

WirePlay v1.0.0-beta.1, tested 2026-09-28 by Muhammad Tariq (@MedProMuha).

> For Claude or anyone picking this up: every item below was checked against the source at upstream commit `0a48a3b`. Line numbers refer to that commit (this PR's header comment edit shifts later `main.swift` lines by one). Items are labeled **Fixed in this PR (tested)** or **Suggestion (not tested)**. Suggestions come from reading the code; I could not reproduce them without a TV and a multi-display setup. Ben has final say on all of it.

Ben, WirePlay installed and launched on my MacBook Pro once I got past one installer bug, and the idea is genuinely useful for our conference rooms. This PR fixes the four things I could reproduce and prove on my Mac. Everything else is a note for you to take or leave.

**Test setup:** MacBook Pro, Apple silicon (arm64), macOS 27.2, Xcode installed, stock `/bin/bash` 3.2.57.

## What works well

- **Release build.** The v1.0.0-beta.1 app and its Control Center extension are both universal (arm64 + x86_64), pass `codesign --verify --deep --strict`, and the extension registered with `pluginkit` on install. The app launched and logged its startup to `~/Library/Logs/WirePlay.log`.
- **Clean compile.** `Sources/main.swift` built with zero warnings in Swift 5 mode.
- **The product idea.** AirPlay-style "show only this window" for HDMI is exactly the gap people hit in conference rooms. Remembering each monitor with a per-room rule is a smart touch.
- **Thoughtful details in the code.** Keeping the pointer on the laptop, only drawing the TV cursor over shared content, the Grammarly overlay workaround, and cropping letterbox padding so shared windows fill the TV.
- **Low-permission path.** Per the README, Mirror and Extended need no permissions and the macOS picker avoids Screen Recording. That should make IT approval easier.

## Fixed in this PR (tested)

### 1. The one-line installer failed on stock macOS

`install.sh:25` was `echo "Installing to $DEST…"`. macOS ships Bash 3.2 as `/bin/bash`, and under a UTF-8 locale it reads the first byte of `…` as part of the variable name, so `set -u` aborts before anything is installed:

```
Downloading WirePlay-1.0.0-beta.1.zip…
/bin/bash: line 25: DEST�: unbound variable
```

| Locale (stock `/bin/bash` 3.2.57) | Original | Fixed |
| --- | --- | --- |
| `en_US.UTF-8` (Terminal default) | Fails at line 25 | Installs |
| `C.UTF-8` | Fails | not separately tested |
| `C` | Works | not separately tested |

If it works on your machine, your shell may be a newer Bash or a non-UTF-8 locale. This was the only line in `install.sh` or `build.sh` with that pattern.

**Fix:** `${DEST}`. **Test:** piped both versions of `install.sh` into `/bin/bash` with `LANG=en_US.UTF-8`, the way the README runs it. Original: exit 1 at line 25. Fixed: exit 0, app replaced in `/Applications`, signature valid, app relaunched.

### 2. A failed install could delete the existing app

`install.sh:27-28` removed the installed app before moving the new one in, so if the move failed the user was left with nothing.

**Fix:** check the download contains `WirePlay.app`, move the current copy into the temp folder, and put it back if the new one can't be moved in. A `trap` cleans up the temp folder.

**Test** (both scripts pointed at a throwaway folder with a fake "previous" app, the move forced to fail, `pkill` disabled):

| Scenario | Original | Fixed |
| --- | --- | --- |
| Move fails | exit 1, previous app gone (0 copies) | exit 1, "Your previous WirePlay was put back.", previous app intact |
| Fresh machine, no previous app | not tested | exit 0, app installed, signature valid |
| Normal reinstall over `/Applications` | fails at line 25 (see above) | exit 0, single copy, no leftovers |

### 3. Release builds could ship with a bad signature

`build.sh:90` was `codesign --verify ... && echo "Signature verified..."`. Under `set -e`, a failure on the left of `&&` does not stop the script, so the zip was still produced.

**Fix:** run `codesign --verify` on its own line.

**Test:** unzipped a release, appended a byte to `AppIcon.icns` to break the signature, and ran both versions under `zsh` with `set -euo pipefail`. Old: printed "kept going", exit 0. New: stopped, exit 1. A full `./build.sh --release` with the fix still succeeds (universal app and extension, 676K zip, "Signature verified on the unzipped app").

### 4. Local source builds always targeted arm64

`build.sh:42` hard-coded `-target arm64-apple-macos26.0`, so `./build.sh` on an Intel Mac would build an app that can't run there, while the README lists Intel.

**Fix:** use `uname -m` for the target and the extension's `-arch`.

**Test:** `./build.sh` on my Mac printed "Compiling (arm64)…", produced an arm64 app, and signed clean. I don't have an Intel Mac, so the x86_64 path is untested.

### Also: header comment

`main.swift:9-11` said Window or App uses the system picker and needs no Screen Recording. The default is now WirePlay's own grid, which does need it. Comment only, no code change.

## Suggestions (not tested), ranked by impact on a presenter

1. **Two displays connected at once: only the last one gets asked.** `rescan()` 1226-1232 calls `showChooser` for each new display, and `showChooser` begins with `chooser?.close()` (1239), closing the first panel without resolving it. Idea: queue the choosers, or one chooser listing each display.
2. **Lid closed with only the TV attached.** `place()` 1286-1291 falls back to `NSScreen.main`, which would be the TV. The cover window is `.screenSaver` level (757) and the chooser and window grid are `.floating` (1246, 1349), so the grid would open under the black cover. Idea: disable Window or App when there's no other screen.
3. **Late async callbacks could undo a newer choice.** `waitForScreen` (1316-1320) calls `beginWindowMode` without checking the mode is still Window or App. Multi-window `share()` (1385-1399) applies after an `await` without checking `target`. `Capture.apply` stores `stream` before `startCapture` completes (855-865). Idea: a generation counter bumped on each mode change and checked in each callback.
4. **Capture and pointer tracking work.** Capture requests up to 60 fps with `queueDepth` 5 at the shared content's full pixel size (825-826). The cursor timer runs at 60 Hz (929) and copies the system window list every third tick, about 20 times a second (937). The window grid starts a screenshot for every listed window at once (627-642). Idea: measure in Activity Monitor during a real talk, then consider 30 fps, fewer window-list calls, and a cap on concurrent thumbnails.
5. **Stray-window rescue makes Accessibility calls on the main thread** every second (1457, 229). An unresponsive app can make those calls wait until they time out. Idea: `AXUIElementSetMessagingTimeout`, or a background queue.
6. **A brief disconnect ends Window or App.** `rescan()` 1217-1218 ends window mode when the display id disappears, and on return it's treated as a new connection. Idea: a short grace period that resumes if the same monitor key comes back.
7. **Monitors sharing a key.** The key is vendor-model-serial (261). If a display reports 0 as its serial, every unit of that model shares one saved rule. Idea: note "shared by all monitors of this model" in Settings when serial is 0.
8. **Mirroring failures are silent.** `apply()` ignores `setMirroring`'s result (1301, 1304). Idea: a short alert on failure.
9. **Install trust.** `install.sh` runs whatever is on `main`, has no checksum, and clears quarantine (34). Idea: publish a SHA-256 per release; longer term, Developer ID signing and notarization would remove the quarantine step and likely the permission re-prompts after updates.

### Smaller items

- **Two install locations.** `install.sh` uses `/Applications`, `build.sh --install` uses `~/Applications` (98), so both can end up installed.
- **Version numbers differ.** App `1.0.0-beta.1`, Control Center extension `1.0.4`.
- **"Try Again" after a capture failure** (1138) picks the first external display, not necessarily the one that failed.
- **Virtual display detection** (274-275) matches "airplay" or "sidecar" in the display name, which may not match on non-English systems.
- **Log file** has no size limit and is written from more than one thread.
- **Swift 6 mode** reports two errors: `Store.shared` (91) and `kAXTrustedCheckOptionPrompt` (446).

## Ideas for future versions

1. **"What the room sees" preview** in the menu, so presenters can confirm the TV without turning around.
2. **Global hotkey for Blank Screen**, for when a sensitive notification pops up.
3. **Room presets** built on the per-monitor memory, for example turning on Do Not Disturb for "Board Room TV".
4. **"New version available"** item in the menu to make beta updates easier.
5. **Follow the frontmost presentation app**, so switching between Keynote and a browser doesn't mean reopening the grid.

## How I tested, and what is not covered

- Installed v1.0.0-beta.1 with `install.sh`; checked signatures, architectures, extension registration and the launch log.
- Built from source (`./build.sh` and `./build.sh --release`) before and after the fixes, and type-checked with `-swift-version 6`.
- Reviewed every file with Claude, plus a second pass from Grok. Only items I could point to in the code are included; several of Grok's claims didn't hold up and were left out (for example it suggested the extension builds single-architecture, but the shipped extension is universal).
- **Not tested:** a real TV or projector, two external displays, clamshell mode, the Screen Recording and Accessibility prompts, the Control Center button, and anything on an Intel Mac.

Happy to walk through any of it.
