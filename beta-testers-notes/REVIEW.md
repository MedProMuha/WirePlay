# WirePlay AirPlay beta review

> Historical pre-install audit. Native fixes and current verification are described in [NATIVE_IMPLEMENTATION.md](NATIVE_IMPLEMENTATION.md).

Reviewed October 7, 2026, before installation. Source: [PR #2](https://github.com/ben-medpro/WirePlay/pull/2), `airplay`, commit `0b45184dfe0cead28c211bb425effdd162a61a95`. Base: `f4b7f04e926be5fa2a4c02ba8353f34d5bfff3cd`.

**Recommendation: fix the privacy lifecycle and cancellation defects before using this beta for a real presentation.** The source builds, but a successful build does not establish safe TV behavior. No actual TV connection was attempted.

The installed `/Applications/WirePlay.app` remains version `1.0.0-beta.1`; its executable SHA-256 remained `3b6cbe2e9d147994f22cb9fa02234f96ea4c5a9414c4dba4a1832bdd31bf5c15` before and after review. At the time of the pre-install audit, no app-source edits, installation, permission changes, GitHub comments, pushes, or PR changes had been made. This handoff subsequently publishes the audit and simulated design preview only. Native app source is unchanged.

## What was verified

- Full review of the 2,314-line application source, Control Center extension, build and installation scripts, project configuration, permission declarations, and previous beta notes. Independent runtime, dependency, installer, and interface reviews.
- Native ARM64 build of app and extension completed on macOS 27.2 with Xcode 27.0 / Apple Swift 6.4, in Swift 5 language mode. No compiler warning appeared in the captured build output.
- Shell syntax and property-list validation passed. The installed app's signature verified before review.
- The newly built app's first strict signature verification failed because Finder/file-provider metadata had appeared on the extension. A clean copy made with `ditto --norsrc --noextattr` outside the Desktop passed `codesign --verify --deep --strict`. The original Desktop build is not being presented as a clean distributable. Use clean staging and verify the final installed copy during a later installation.
- The built app's existing `--preview` mode generated a local chooser screenshot; its normal application event loop was not launched. This rendered the current chooser without connecting a display or requesting screen capture. An OS sandbox-extension diagnostic appeared during rendering, but the image was produced and inspected.
- Gitleaks examined seven commits and approximately 165 KB, with no secret findings. The original scan reported no findings; raw scan artifacts are omitted from this handoff. This does not prove absence of malware or every possible secret, and does not cover other remote branches or release binaries.
- Five Swift characterization checks demonstrated cancellation, retry identity, receiver matching, existing-connection, and missing-menu behavior using extracted logic and stub state. See `state-checks.swift`. These checks reproduce source behavior, not macOS/TV integration.
- Three installer failure-injection cases ran using temporary dummy directories. Two demonstrated loss of the previous app; the successful-rollback case preserved it. See `installer-check.py` and `installer-check-results.txt`. The check itself received independent Python review.
- The simulated visual proposal received JavaScript review. Its receiver-to-window-to-presentation flow, Blank/Unblank, Pause/Resume, and reconnect-to-blank behavior were exercised in the browser. Light and dark views were visually inspected. This is not a native accessibility or hardware test.

## Findings, in priority order

All application references below are to `Sources/main.swift` at the reviewed commit. “Source-confirmed” means the faulty control flow is present; it does not mean the physical TV effect was filmed or reproduced.

### 1. High: stopping can expose the desktop

At lines 1863–1868, Stop AirPlay removes the cover through `endWindowMode(false)` before queuing disconnection. Lines 2122–2143 destroy the output window immediately. The disconnect driver at 1499–1511 ignores click failures and logs success without confirming the receiver disconnected.

The system sharing indicator's stop callback at 1618 and app termination at 1668–1672 do not disconnect AirPlay. Switching targets at 1823/2008 also removes the previous cover while its receiver can remain connected. Receiver identity can then refer to TV A while the active capture targets HDMI B.

**Fix:** centralize owned-session cleanup; retain a black cover and receiver identity until disconnection is confirmed. Show a retryable failure. Route Stop, capture failure/termination, target replacement, and Quit through the same lifecycle. A forced crash still needs explicit physical testing and cannot be made safe merely by changing UI wording.

### 2. High: setup can confirm the wrong mode or leave an unprotected connection

At 1465–1483 the driver still presses the sheet's default button if it could not select Extended Display. It searches for an English heading without checking the requested receiver; the `name` argument is unused. At 1842–1860 pending ownership is cleared before cover setup succeeds. The no-other-screen, unmirroring failure, or screen-wait failure paths at 1971–1988 do not roll back AirPlay.

**Fix:** verify receiver and selected mode before confirming. Retain ownership until the cover is established; disconnect on setup failure, cancellation, or late completion. There is a separate first-frame concern: display notifications are debounced by 0.8 seconds at 1704–1707, so a cover created afterward cannot establish a zero-exposure guarantee. Test with harmless content and observe the TV from before connection begins.

### 3. High: Cancel leaves the connection attempt running

At 1793 and 1802–1804, Cancel closes only the panel. Pending state, queued accessibility work, and timeout continue. At 1827–1844 callbacks identify attempts only by TV name, so a timer from a failed attempt can cancel a newer retry to that same TV.

**Fix:** a per-attempt identifier and explicit cancellation, checked at each asynchronous boundary. Roll back late connections. Two extracted Swift checks confirmed these state defects.

### 4. High: AirPlay is missing Blank Screen and window controls

At 2200 the menu filters out virtual displays. Blank Screen, Add or Remove Windows, Change What's Shown, and presentation status are only generated inside that filtered loop at 2205–2218. The separate AirPlay branch at 2233–2234 adds only Stop AirPlay. The menu can say “No external display connected” during AirPlay.

**Fix:** render controls from the active owned presentation, independent of wired-display discovery. The Control Center link can reopen the grid, but it does not supply the missing Blank button. Confirmed by source and an extracted filter check.

### 5. High: Sidecar can be mistaken for the requested TV

The fallback at 1726–1734 accepts a new virtual display with no AirPlay receiver suffix. An iPad Sidecar display qualifies, causing WirePlay to cover the wrong device and clear the real TV request.

**Fix:** require positive receiver identification; never accept arbitrary virtual displays. An extracted Swift check reproduced the match.

### 6. High, pre-existing: stale window selections and capture callbacks can win

At 2065–2084, changing selected windows does not advance the generation used to reject stale asynchronous results. Older multi-window work can overwrite a newer selection in the same session. Stream updates at 903–906 are unsequenced. A stale start failure at 921 calls `onFailed` even when its stream has been replaced; frame delivery at 957–970 lacks a current-stream check.

**Fix:** advance a selection revision and check it plus stream identity before applying results, rendering frames, or reporting errors. The old beta fixes improved mode changes but do not cover these paths. Timing-dependent symptoms remain untested against ScreenCaptureKit.

### 7. Medium: existing AirPlay sessions and retry target selection fail

The connection driver returns when the TV is already on (1449), while completion only considers newly discovered display IDs (1726). An already-known TV therefore times out. Capture-error “Try Again” filters out virtual displays at 1629–1630, so it can do nothing or target a wired monitor instead.

**Fix:** adopt an existing positively matched receiver explicitly and preserve the failed destination for retry. The existing-display predicate was reproduced with a Swift check.

### 8. Medium: discovery errors become endless searching

At 1333 browser failure is only logged. The failed browser remains stored, preventing a fresh start; the UI at 1553 always shows a spinner for an empty list. It does not distinguish permission denial, discovery failure, and no receivers found.

**Fix:** publish discovery state and expose relevant permission guidance plus a retry that recreates a failed browser.

### 9. Medium: the source installer deletes the current app too early

`build.sh:129` deletes the destination before copying the new app; line 126 also deletes the older install location first. Injected copy failure left no previous app or usable replacement.

**Fix:** stage and verify a complete replacement first, preserve a backup, then replace. Verify again at the destination before launching. This directly affects the install command recommended in PR #2.

### 10. Medium: failed rollback deletes its own backup

`install.sh:48` can fail while restoring the previous app. Its unconditional EXIT trap at line 22 then removes the temporary directory containing the only backup. The failure-injection check reproduced that loss; ordinary rollback succeeded.

**Fix:** retain the backup and report its location if restoration fails.

### 11. Medium: checksum verification is optional

`install.sh:26` skips verification if the release has no checksum asset, despite README wording that promises a check.

**Fix:** require the checksum asset and verify the downloaded app's signature before replacing the current installation. A checksum from the same publisher detects corruption; it is not independent publisher authentication. This is an integrity gap, not evidence of a compromised release.

## Dependency and security assessment

**Formal dependency-review verdict: UNKNOWN**, because no supported third-party package manifest/exact package versions were found and live Endor risk evidence was unavailable. This does not mean a risky dependency was found. The reviewed project declares no third-party runtime/build packages: Swift imports are Apple frameworks, the Xcode project has no external package references, and the optional Python glyph generator uses the standard library. No dependency addition or upgrade is indicated. Compiler and SDK versions are recorded above; Swift 5 language mode alone does not pin them. No policy evaluator was supplied, so there is no policy verdict.

No apparent credential theft, hidden upload destination, or downloaded executable stage was found in the reviewed application/build code. The installer intentionally downloads GitHub releases. The app uses Bonjour discovery and macOS AirPlay; screen capture and Accessibility remain powerful permissions. The main app is not sandboxed; the Control Center extension is. Release signing is ad hoc, not notarized publisher authentication. These facts do not outweigh the concrete privacy defects above.

Logs can include receiver names, application names, and accessibility-tree labels/values. Review and redact logs before posting them publicly; no logs from the user's live app were uploaded.

## Visual and usability proposal

Open [visual-preview.html](visual-preview.html) locally in a browser. The complete HTML, CSS, and JavaScript are included in one file with no dependency installation. It is a concept with invented rooms/documents and simulated actions. It does not capture the screen, control a TV, change permissions, or contact a service. [presenter-concept-v2.jpg](presenter-concept-v2.jpg) shows the refined proposal. All 16 built-in prototype checks passed; the changes and their limits are listed in [README.md](README.md).

1. Keep the native menu-bar app. Add a compact, optional presenter panel with destination, selected windows, outgoing preview, Blank, Stop, and clear status. An outgoing preview cannot certify what a physical TV displays.
2. Give the window picker search, refresh, readable app/title labels, selection count, and keyboard-accessible native controls. Current gesture-only cards are at 383/718; titles are 11-point and truncated at 791.
3. Replace indefinite thumbnail spinners with an app icon and “Preview unavailable” when capture completes without an image (695/774).
4. Distinguish initial “Disconnect” from “Cancel changes” during an active presentation. Make permission recovery and no-TV/no-window states actionable.
5. Add a deliberate global Blank shortcut. Consider Pause as a separate enhancement: Pause holds the previous frame, Blank hides it, Stop disconnects. Pause is not currently implemented in the native app.
6. Label audio behavior. Capture explicitly sets `capturesAudio = false` at 885; do not imply WirePlay is forwarding audio. Actual macOS system audio routing still needs hardware verification.

The existing beta notes already proposed outgoing preview and a global blank shortcut. Other old findings are fixed in this branch: queued display choosers, initial closed-lid guard, four-thumbnail concurrency, 30 fps capture, background window rescue with timeouts, cable reconnect grace, serial-number warning, mirroring alerts, and bounded serialized logging. These should not be reported to Ben as new defects. Defer automatic frontmost-app sharing and broad redesign until the safety lifecycle works.

## Physical acceptance checklist still outstanding

| PR checklist | Current evidence / remaining work |
|---|---|
| Build/install | ARM64 build completed; clean staged signature passed. Installation deliberately not performed. |
| Local Network / Accessibility | Declarations/source reviewed; prompts and actual permission transitions untested. |
| Pick TV, connect, black cover, grid | Source reviewed; observe physical TV throughout initial connection, including a saved Mirror default. |
| Select one window, add second | Grid logic reviewed; AirPlay menu defect found. Verify actual content, layout, and removal after repair. |
| Blank then Stop | Controls/lifecycle defects found. Verify no private desktop on stop, failure, and Quit after repair. |
| Control Center with no HDMI | Extension built; actual button interaction untested. |
| First-use macOS show-mode sheet | Unsafe fallback found. Test real sheet, PIN prompt, delays, localization, and saved defaults. |

Additional cases: cancel during connection; retry same TV; adopt an already-connected TV; Sidecar appearing simultaneously; change target; stop through macOS indicator; lose Accessibility mid-session; disconnect/reconnect network; lid close; screen sleep/wake; stale window selections; crash; Intel build/device; VoiceOver and keyboard. Verify with harmless test windows and a free TV before any private presentation.

This branch preserves the reviewed native source unchanged and publishes the findings, full prototype code, and isolated checks. [DEVELOPER_NOTES.md](DEVELOPER_NOTES.md) summarizes the handoff for Ben. All native fixes and physical-device acceptance checks remain outstanding.
