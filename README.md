# WirePlay

AirPlay's *"What do you want to show?"* sheet, for **wired** (HDMI / USB-C) displays.

When you plug a Mac into a conference-room TV, macOS only offers mirroring or an extended desktop. AirPlay lets you show just one window or app and keep everything else private. WirePlay brings that choice to wired displays: plug in, pick what to show, and only that appears on the TV.

A small menu bar app for macOS 26 or later, on Apple silicon or Intel Macs.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ben-medpro/WirePlay/main/install.sh | bash
```

This downloads the latest release, checks it against the release's published SHA-256 checksum, installs it into `/Applications` (your previous copy is kept until the new one is in place), clears the download quarantine (the app isn't notarized) and opens it. You can also download the zip from [Releases](https://github.com/ben-medpro/WirePlay/releases), move `WirePlay.app` to Applications, then right-click it and choose **Open** the first time.

## How it works

When an external display connects, WirePlay asks what to show on it:

| Option | What happens |
|---|---|
| **Entire Screen** | Normal macOS mirroring of your Mac's screen. |
| **Window or App** | The TV turns black and shows only the windows you choose, from a grid of your open windows. Pick one window and it fills the TV. Pick several and they appear where they sit on your screen, like AirPlay. |
| **Extended Display** | A normal second desktop. |

While you're showing windows:

- **Your pointer stays on your Mac.** It can't wander onto the TV, and you can't drag a window across by accident.
- **The TV only shows your pointer when it's over a shared window.** It's hidden everywhere else.
- **A brief disconnect doesn't end it.** If the cable blips or the TV switches inputs, WirePlay keeps going for 15 seconds and resumes when the same monitor comes back.
- **Stray windows come back.** Any window that ends up on the TV is moved back to your Mac. This needs Accessibility permission, which you grant from Settings.
- **Add or remove windows at any time** from the menu bar icon or the Control Center button. **Blank Screen** hides everything for a moment.

## Remembering monitors

WirePlay remembers every monitor it sees, by make, model and serial number. Each one gets a rule for when it's connected: **Ask Every Time**, **Mirror**, **Window or App**, **Extended**, or **Ignore** (leave it to macOS, for example your desk monitor). You can also rename a monitor, for example "Conference Room TV".

You can set these rules in three places:

- The chooser: **Set as Default** or **Ignore this display**.
- The menu bar icon's **When Connected** submenu.
- **Settings…** (also opens when you double-click the app).

## Control Center button

Open Control Center, click **Edit Controls**, search for **WirePlay**, and drag it into Control Center or the menu bar. Tapping it opens the chooser, or the window grid if you're already sharing.

## Permissions

- **Screen Recording.** Needed for the Window or App grid (to list windows and show previews) and for drawing the shared windows on the TV. WirePlay asks the first time you use it. Turn it on under *System Settings › Privacy & Security › Screen & System Audio Recording*.
- **Accessibility** (optional). Needed only to move stray windows back off the TV. Grant it from WirePlay's Settings.

Mirroring and Extended Display need no permissions. If you'd rather not grant Screen Recording, Settings can switch Window or App to the macOS window picker, which doesn't need it. Its hover buttons can be hard to click when you have many windows open, though.

## Known limits (beta)

- **Window or App needs your Mac's own screen.** With the lid closed and only the TV attached, that option is greyed out; use Entire Screen, or open the lid.
- **Several displays at once:** WirePlay asks about each one in turn, but shows windows on only one display at a time.

- The app is ad hoc signed, not notarized. After an update, macOS may ask you to allow Screen Recording or Accessibility again.
- If an app floats invisible windows over others (Grammarly does), WirePlay leaves those apps out of the window list automatically.
- **Monitors without a serial number:** some monitors don't report one, so every monitor of that model shares one name and rule. Settings marks these.
- **Which version am I running?** The version and the git commit it was built from are at the bottom of the menu bar menu, and in the first line of the log.
- Troubleshooting log: `~/Library/Logs/WirePlay.log` (it rolls over at 1 MB).

## Build from source

```bash
./build.sh --install    # build for this Mac, install to /Applications and launch
./build.sh --release    # universal, ad-hoc-signed zip + .sha256 in ./dist
```

The app is a single Swift file (`Sources/main.swift`) built with `swiftc`. The Control Center button is a small WidgetKit extension (`Controls/`, `WirePlayControls.xcodeproj`), so building it needs Xcode in `/Applications`. Without Xcode, the app builds without the button.

## License

MIT
