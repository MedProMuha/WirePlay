// WirePlay — AirPlay-style "what do you want to show?" for wired (HDMI / USB-C) displays.
//
// When an external display is connected, WirePlay asks what to show on it:
//   • Entire Screen    — macOS hardware mirroring of the built-in display.
//   • Window or App    — the display is covered by a black WirePlay window and only the
//                        windows / apps picked in WirePlay's window grid are drawn on it.
//   • Extended Display — a normal extended desktop.
//
// Window or App lists windows in WirePlay's own grid by default (WindowPickerModel), which needs
// Screen Recording permission. Settings can switch to ScreenCaptureKit's SCContentSharingPicker,
// the system picker AirPlay and video-call apps use, which needs no permission. Either way,
// windows can be added or removed later. While it shows windows, the pointer (and any stray window) is kept off
// that display so nothing gets lost behind the presentation.
//
// Each monitor is remembered with a rule: ask, one of the three modes, or ignore (leave it to macOS).

import Cocoa
import Combine
import CoreMedia
import Network
@preconcurrency import ScreenCaptureKit
import ServiceManagement
import SwiftUI

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WirePlay.log")

private let logQueue = DispatchQueue(label: "WirePlay.log")
private let logTimestamp = ISO8601DateFormatter() // only used on logQueue

func log(_ message: String) {
    let date = Date()
    logQueue.async {
        guard let data = "\(logTimestamp.string(from: date)) \(message)\n".data(using: .utf8) else { return }
        // Keep it small: past 1 MB the log moves to WirePlay.log.1 and a new one starts.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
            let old = logURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

/// "1.0.0-beta.2 (d8670a7)": version plus the git commit the app was built from.
let appVersion: String = {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "?"
    return info["WirePlayCommit"].map { "\(version) (\($0))" } ?? version
}()

// MARK: - Model

enum ShowMode: String, CaseIterable, Identifiable {
    case entireScreen, windowOrApp, extendedDisplay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .entireScreen: return "Entire Screen"
        case .windowOrApp: return "Window or App"
        case .extendedDisplay: return "Extended Display"
        }
    }

    var buttonTitle: String {
        switch self {
        case .entireScreen: return "Mirror Entire Screen"
        case .windowOrApp: return "Choose Window or App"
        case .extendedDisplay: return "Use as Extended Display"
        }
    }

    func explanation(_ name: String) -> String {
        switch self {
        case .entireScreen: return "Everything on your screen will be visible on “\(name)”."
        case .windowOrApp: return "Only the window or app you have selected will be visible on “\(name)”."
        case .extendedDisplay: return "“\(name)” will act as a separate display you can move windows to."
        }
    }
}


/// What WirePlay does when a particular monitor is connected.
enum Rule: String, CaseIterable, Identifiable {
    case ask, entireScreen, windowOrApp, extendedDisplay, ignore
    var id: String { rawValue }

    init(_ mode: ShowMode) { self = Rule(rawValue: mode.rawValue)! }
    var mode: ShowMode? { ShowMode(rawValue: rawValue) }

    var title: String {
        switch self {
        case .ask: return "Ask Every Time"
        case .entireScreen: return "Mirror Entire Screen"
        case .windowOrApp: return "Show Window or App"
        case .extendedDisplay: return "Use as Extended Display"
        case .ignore: return "Ignore (Normal macOS Behavior)"
        }
    }
}

// MARK: - Monitor memory and preferences

final class Store: ObservableObject {
    nonisolated(unsafe) static let shared = Store() // main-thread only

    struct Monitor: Codable, Identifiable {
        var key: String
        var name: String
        var rule: String
        var lastSeen: Date
        var customName: String?          // e.g. "Conference Room TV"
        var id: String { key }
    }

    private let defaults = UserDefaults.standard
    @Published private(set) var monitors: [Monitor] = []
    @Published var connectedKeys: Set<String> = []
    @Published var axTrusted = AXIsProcessTrusted()

    @Published var fencePointer: Bool { didSet { defaults.set(fencePointer, forKey: "fencePointer"); onFenceChange() } }
    @Published var rescueWindows: Bool { didSet { defaults.set(rescueWindows, forKey: "rescueWindows"); onFenceChange() } }
    @Published var useSystemPicker: Bool { didSet { defaults.set(useSystemPicker, forKey: "useSystemPicker") } }
    var onFenceChange: () -> Void = {}

    private init() {
        defaults.register(defaults: ["fencePointer": true, "rescueWindows": true])
        fencePointer = defaults.bool(forKey: "fencePointer")
        rescueWindows = defaults.bool(forKey: "rescueWindows")
        useSystemPicker = defaults.bool(forKey: "useSystemPicker")
        if let data = defaults.data(forKey: "monitors"), let list = try? JSONDecoder().decode([Monitor].self, from: data) {
            monitors = list
        }
        // Carry over monitors and "Set as Default" choices saved by the first version.
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix("name.") {
            let key = String(k.dropFirst("name.".count))
            if monitor(key) == nil, let name = v as? String {
                monitors.append(Monitor(key: key, name: name, rule: Rule.ask.rawValue, lastSeen: Date()))
            }
            defaults.removeObject(forKey: k)
        }
        save()
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix("default.") {
            let key = String(k.dropFirst("default.".count))
            if let raw = v as? String, Rule(rawValue: raw) != nil {
                setRule(Rule(rawValue: raw)!, for: key, name: monitor(key)?.name)
            }
            defaults.removeObject(forKey: k)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(monitors) { defaults.set(data, forKey: "monitors") }
    }

    func monitor(_ key: String) -> Monitor? { monitors.first { $0.key == key } }
    func rule(for key: String) -> Rule { monitor(key).flatMap { Rule(rawValue: $0.rule) } ?? .ask }

    func remember(_ key: String, name: String?) {
        if let i = monitors.firstIndex(where: { $0.key == key }) {
            if let name { monitors[i].name = name }
            monitors[i].lastSeen = Date()
        } else {
            monitors.append(Monitor(key: key, name: name ?? "External Display", rule: Rule.ask.rawValue, lastSeen: Date()))
        }
        save()
    }

    func setRule(_ rule: Rule, for key: String, name: String? = nil) {
        remember(key, name: name)
        if let i = monitors.firstIndex(where: { $0.key == key }) { monitors[i].rule = rule.rawValue }
        save()
        log("rule for \(key) = \(rule.rawValue)")
    }

    func rename(_ key: String, to newName: String) {
        guard let i = monitors.firstIndex(where: { $0.key == key }) else { return }
        let t = newName.trimmingCharacters(in: .whitespaces)
        monitors[i].customName = t.isEmpty ? nil : t
        save()
    }

    func forget(_ key: String) { monitors.removeAll { $0.key == key }; save() }
}

// MARK: - Keeping the pointer and windows off the presentation display

/// Pushes the pointer back whenever it crosses onto the fenced screen. Global mouse monitors
/// need no permission. Because a dragged window follows the pointer, this also stops windows
/// from being dragged across.
final class PointerFence {
    private var monitors: [Any] = []
    private var fenced: NSRect = .zero // Cocoa coordinates

    var isActive: Bool { !monitors.isEmpty }

    func start(fencing frame: NSRect) {
        fenced = frame
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.check() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.check(); return e }) { monitors.append(m) }
        check()
    }

    func stop() { monitors.forEach(NSEvent.removeMonitor); monitors = [] }

    private func check() {
        let p = NSEvent.mouseLocation
        guard fenced.contains(p) else { return }
        // Nearest point on any other screen (normally the MacBook's).
        let targets = NSScreen.screens.map(\.frame).filter { $0 != fenced }.map { f -> NSPoint in
            let r = f.insetBy(dx: 1, dy: 1)
            return NSPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
        }
        guard let q = targets.min(by: { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }),
              let primaryHeight = NSScreen.screens.first?.frame.maxY else { return }
        CGWarpMouseCursorPosition(CGPoint(x: q.x, y: primaryHeight - q.y)) // CG uses top-left origin
        CGAssociateMouseAndMouseCursorPosition(1) // no post-warp pointer freeze
    }
}

/// Moves any window that ends up on the fenced display back to the MacBook screen.
/// Needs Accessibility permission; without it this does nothing.
enum WindowRescue {
    static func run(fenced: CGRect, home: CGRect) {
        guard AXIsProcessTrusted(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        var pids = Set<pid_t>()
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b),
                  fenced.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            pids.insert(pid)
        }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5) // an unresponsive app mustn't stall us
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for win in windows {
                guard let frame = frame(of: win), fenced.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                // Keep its relative spot, scaled into the home screen.
                let rx = (frame.minX - fenced.minX) / max(fenced.width, 1), ry = (frame.minY - fenced.minY) / max(fenced.height, 1)
                var origin = CGPoint(x: home.minX + rx * max(home.width - frame.width, 0),
                                     y: home.minY + 25 + ry * max(home.height - 25 - frame.height, 0))
                origin.x = min(origin.x, home.maxX - 100); origin.y = min(origin.y, home.maxY - 100)
                if let v = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
                    log("moved a window of pid \(pid) back to the MacBook screen")
                }
            }
        }
    }

    private static func frame(of win: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}

struct ExternalDisplay: Equatable {
    let id: CGDirectDisplayID

    /// Stable across reconnects (display IDs are not), used for "Set as Default".
    var key: String { "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))" }

    /// Some monitors report serial number 0, so every unit of that model shares one key (and rule).
    static func keyHasNoSerial(_ key: String) -> Bool { key.hasSuffix("-0") }
    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == id } }
    var isMirrored: Bool { CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay }

    /// The name you gave it in Settings, else the AirPlay receiver's name, else what the monitor calls itself.
    var name: String { Store.shared.monitor(key)?.customName ?? airPlayNames[id] ?? airPlayReceiver ?? hardwareName }

    /// macOS names an AirPlay display "<receiver> (AirPlay)", e.g. "Mike-Office (AirPlay)".
    var airPlayReceiver: String? {
        let n = hardwareName
        return n.hasSuffix(" (AirPlay)") ? String(n.dropLast(" (AirPlay)".count)) : nil
    }

    var hardwareName: String {
        screen?.localizedName ?? Store.shared.monitor(key)?.name ?? "External Display"
    }

    /// AirPlay / Sidecar create virtual displays; those already have their own UI.
    var isVirtual: Bool {
        let n = hardwareName.lowercased()
        return n.contains("airplay") || n.contains("sidecar")
    }

    static func online() -> [ExternalDisplay] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map(ExternalDisplay.init)
    }
}

/// AirPlay displays WirePlay started, by display ID → receiver name ("Executive-Room").
var airPlayNames: [CGDirectDisplayID: String] = [:]

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The display to mirror: the built-in panel if there is one, otherwise the main display.
func primaryDisplayID(excluding ext: CGDirectDisplayID) -> CGDirectDisplayID {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.first { CGDisplayIsBuiltin($0) != 0 } ?? ids.first { $0 != ext } ?? CGMainDisplayID()
}

@discardableResult
func setMirroring(_ display: CGDirectDisplayID, on: Bool) -> Bool {
    let master = on ? primaryDisplayID(excluding: display) : kCGNullDirectDisplay
    if (CGDisplayMirrorsDisplay(display) != kCGNullDirectDisplay) == on { return true }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    CGConfigureDisplayMirrorOfDisplay(config, display, master)
    let err = CGCompleteDisplayConfiguration(config, .forSession)
    log("mirroring \(on ? "on" : "off") for \(display): \(err.rawValue)")
    return err == .success
}


// MARK: - Chooser UI (a replica of the AirPlay sheet)

enum ChooserResult { case cancel, show(ShowMode, remember: Bool), ignore }

final class ChooserModel: ObservableObject {
    @Published var mode: ShowMode = .windowOrApp
    @Published var setAsDefault = false
    let displayName: String
    let showingWindows: Bool   // already presenting windows on this display
    let windowModeAvailable: Bool // false when this display is the Mac's only screen (lid closed)
    var onDone: (ChooserResult) -> Void = { _ in }
    init(displayName: String, initial: ShowMode, showingWindows: Bool = false, windowModeAvailable: Bool = true) {
        self.displayName = displayName; self.showingWindows = showingWindows
        self.windowModeAvailable = windowModeAvailable
        self.mode = (initial == .windowOrApp && !windowModeAvailable) ? .entireScreen : initial
    }

    func isAvailable(_ mode: ShowMode) -> Bool { mode != .windowOrApp || windowModeAvailable }

    var buttonTitle: String {
        showingWindows && mode == .windowOrApp ? "Add or Remove Windows" : mode.buttonTitle
    }
}

struct ChooserView: View {
    @ObservedObject var model: ChooserModel

    var body: some View {
        VStack(spacing: 0) {
            Text("What do you want to show on “\(model.displayName)”?")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 26).padding(.bottom, 22)

            HStack(spacing: 18) {
                ForEach(ShowMode.allCases) { mode in
                    ModeCard(mode: mode, selected: model.mode == mode)
                        .opacity(model.isAvailable(mode) ? 1 : 0.35)
                        .onTapGesture(count: 2) {
                            guard model.isAvailable(mode) else { return }
                            model.mode = mode; model.onDone(.show(mode, remember: model.setAsDefault))
                        }
                        .onTapGesture { if model.isAvailable(mode) { model.mode = mode } }
                        .help(model.isAvailable(mode) ? "" : "Needs your Mac’s own screen. Open the lid (or connect another display) to show just a window.")
                }
            }
            .padding(.horizontal, 26)

            Text(model.windowModeAvailable ? model.mode.explanation(model.displayName)
                 : "\(model.mode.explanation(model.displayName)) Window or App needs your Mac’s own screen, so it’s off while the lid is closed.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26)
                .padding(.top, 22).padding(.bottom, 20)

            Divider().padding(.horizontal, 26)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Set as Default", isOn: $model.setAsDefault).toggleStyle(.checkbox)
                    Button { model.onDone(.ignore) } label: {
                        Text("Ignore this display").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                        .help("WirePlay won’t ask again for this monitor; macOS handles it as usual. Change this in WirePlay Settings.")
                }
                Spacer()
                Button("Cancel") { model.onDone(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(model.buttonTitle) { model.onDone(.show(model.mode, remember: model.setAsDefault)) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 26).padding(.vertical, 16)
        }
        .frame(width: 600)
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var store = Store.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @FocusState private var editing: String?

    static let shortDate: DateFormatter = { // 9/23/26 4:16 PM
        let f = DateFormatter(); f.dateFormat = "M/d/yy h:mm a"; return f
    }()

    var body: some View {
        Form {
            Section {
                if store.monitors.isEmpty {
                    Text("Monitors appear here after you connect them.").foregroundStyle(.secondary)
                }
                ForEach(store.monitors.sorted { $0.lastSeen > $1.lastSeen }) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                // Shows the custom name, or the monitor's own name until you rename it.
                                TextField("", text: Binding(get: { m.customName ?? m.name },
                                                            set: { store.rename(m.key, to: $0 == m.name ? "" : $0) }),
                                          prompt: Text(m.name))
                                    .labelsHidden()
                                    .textFieldStyle(.plain)
                                    .focused($editing, equals: m.key)
                                    .fixedSize()
                                    .help("Click to rename, e.g. “Conference Room TV”. Clear it to use the monitor’s own name.")
                                Button { editing = m.key } label: {
                                    Image(systemName: "pencil").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless).help("Rename")
                            }
                            Text("\(m.name)\(ExternalDisplay.keyHasNoSerial(m.key) ? " (every one of this model)" : "") · "
                                 + (store.connectedKeys.contains(m.key) ? "Connected"
                                    : "Last connected \(Self.shortDate.string(from: m.lastSeen))"))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(ExternalDisplay.keyHasNoSerial(m.key)
                                      ? "This monitor doesn’t report a serial number, so this name and rule apply to every monitor of the same model."
                                      : "")
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { store.rule(for: m.key) }, set: { store.setRule($0, for: m.key) })) {
                            ForEach(Rule.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                        Button { store.forget(m.key) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Forget this monitor")
                    }
                }
            } header: {
                Text("When a monitor is connected")
            } footer: {
                Text("“Ignore” leaves the monitor to macOS, e.g. your desk monitor. Monitors are recognised by make, model and serial number.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Choose windows with the macOS picker", isOn: $store.useSystemPicker)
                Toggle("Keep the pointer on this Mac’s screen", isOn: $store.fencePointer)
                Toggle("Move windows that land on the presentation display back", isOn: $store.rescueWindows)
                if store.rescueWindows && !store.axTrusted {
                    HStack {
                        Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Grant Access…") {
                            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                }
            } header: {
                Text("While showing a window or app")
            } footer: {
                Text("WirePlay’s own window list (the default) needs Screen Recording permission. The macOS picker doesn’t, but its hover buttons can be hard to click when many windows are open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        UserDefaults.standard.set(on, forKey: "launchAtLogin") // lets launch re-register after a move
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { log("login item: \(error)") }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 680, height: 480)
        .onReceive(tick) { _ in store.axTrusted = AXIsProcessTrusted() }
    }
}

struct ModeCard: View {
    let mode: ShowMode
    let selected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05))
                illustration.padding(14)
            }
            .frame(width: 168, height: 126)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: selected ? 4 : 0))
            Text(mode.title).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder var illustration: some View {
        switch mode {
        case .entireScreen:
            TV { ZStack { Wallpaper(); MiniWindow().frame(width: 58, height: 40).offset(x: -20, y: -4)
                          MiniWindow(sidebar: false).frame(width: 44, height: 36).offset(x: 26, y: 8) } }
        case .windowOrApp:
            TV { ZStack { Color.black; MiniWindow().frame(width: 84, height: 54) } }
        case .extendedDisplay:
            ZStack(alignment: .bottom) {
                TV { Wallpaper() }
                Laptop().frame(width: 62, height: 40).offset(y: 4)
            }
        }
    }
}

struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.12, green: 0.24, blue: 0.55), Color(red: 0.95, green: 0.6, blue: 0.35),
                                Color(red: 0.2, green: 0.35, blue: 0.7)], startPoint: .bottomLeading, endPoint: .topTrailing)
    }
}

struct TV<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black))
                .aspectRatio(16 / 10, contentMode: .fit)
            Capsule().fill(Color.gray.opacity(0.7)).frame(width: 44, height: 5).padding(.top, 1)
        }
    }
}

struct MiniWindow: View {
    var sidebar = true
    var body: some View {
        HStack(spacing: 0) {
            if sidebar { Color(red: 0.86, green: 0.89, blue: 0.95).frame(width: 18) }
            Color.white
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 1.5) { Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green) }
                .frame(width: 10, height: 3).padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(radius: 1)
    }
}

struct Laptop: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack { Wallpaper(); MiniWindow().frame(width: 26, height: 18).offset(x: -6, y: -2) }
                .padding(2).background(RoundedRectangle(cornerRadius: 2).fill(Color.black))
            RoundedRectangle(cornerRadius: 1).fill(Color.gray).frame(height: 3).padding(.horizontal, -5)
        }
    }
}

// MARK: - WirePlay's own window chooser
//
// The macOS picker's hover buttons ("Share This Window") are unreliable when many windows are
// stacked at the same size, and when apps float invisible overlays (Grammarly): the picker
// flips between windows as the pointer moves and the button collapses before it can be
// clicked. This chooser is a plain grid you click instead. It needs Screen Recording permission.

final class WindowPickerModel: ObservableObject {
    struct Item: Identifiable {
        let window: SCWindow
        let app: String
        let title: String
        let icon: NSImage?
        var id: CGWindowID { window.windowID }
    }

    @Published var items: [Item] = []
    @Published var thumbs: [CGWindowID: NSImage] = [:]
    @Published var selected: Set<CGWindowID>
    @Published var loading = true
    @Published var failure: String?
    let displayName: String
    var onDone: ([SCWindow]?) -> Void = { _ in }   // nil = cancelled
    var onUseSystemPicker: () -> Void = {}

    init(displayName: String, selected: Set<CGWindowID>) {
        self.displayName = displayName
        self.selected = selected
    }

    var chosen: [SCWindow] { items.filter { selected.contains($0.id) }.map(\.window) }

    var showTitle: String {
        switch selected.count {
        case 0: return "Show Windows"
        case 1: return "Show 1 Window"
        default: return "Show \(selected.count) Windows"
        }
    }

    func toggle(_ id: CGWindowID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Lists shareable windows, front-most first, then fills in thumbnails.
    @MainActor
    func load(excludingBundleIDs excluded: Set<String>, excludingArea tv: CGRect?) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // CGWindowList is ordered front to back; use it to put recently used windows first.
            let order = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .enumerated().reduce(into: [CGWindowID: Int]()) { map, e in
                    if let id = e.element[kCGWindowNumber as String] as? CGWindowID { map[id] = e.offset }
                }
            let windows = content.windows.filter { w in
                guard w.windowLayer == 0, w.isOnScreen, w.frame.width >= 120, w.frame.height >= 80,
                      let app = w.owningApplication, !excluded.contains(app.bundleIdentifier) else { return false }
                if let tv, tv.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) { return false } // on the TV itself
                return true
            }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }

            items = windows.map { w in
                let app = w.owningApplication!
                let running = NSRunningApplication(processIdentifier: app.processID)
                return Item(window: w, app: app.applicationName, title: w.title ?? "", icon: running?.icon)
            }
            selected = selected.intersection(Set(items.map(\.id)))
            loading = false
        } catch {
            log("window list failed: \(error)")
            failure = error.localizedDescription
            loading = false
            return
        }

        // At most 4 screenshots at a time, so opening the grid with many windows stays light.
        var queue = items.map(\.window).makeIterator()
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for _ in 0..<4 { if let w = queue.next() { group.addTask { await Self.thumbnail(of: w) } } }
            for await (id, image) in group {
                if let image { thumbs[id] = image }
                if let w = queue.next() { group.addTask { await Self.thumbnail(of: w) } }
            }
        }
    }

    private static func thumbnail(of w: SCWindow) async -> (CGWindowID, NSImage?) {
        let c = SCStreamConfiguration()
        let scale = 360 / max(w.frame.width, 1)
        c.width = max(2, Int(w.frame.width * scale))
        c.height = max(2, Int(w.frame.height * scale))
        c.showsCursor = false
        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: c) else { return (w.windowID, nil) }
        return (w.windowID, NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }
}

struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose windows to show on “\(model.displayName)”")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 22)
            Text("Click to select one or more windows. Only the selected windows will appear there.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 4).padding(.bottom, 12)

            ZStack {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.items) { item in
                            WindowCard(item: item, thumb: model.thumbs[item.id], selected: model.selected.contains(item.id))
                                .onTapGesture { model.toggle(item.id) }
                        }
                    }
                    .padding(20)
                }
                if model.loading {
                    ProgressView("Finding windows…")
                } else if let failure = model.failure {
                    VStack(spacing: 8) {
                        Text("WirePlay couldn’t list your windows.").font(.headline)
                        Text(failure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(40)
                } else if model.items.isEmpty {
                    Text("No windows to show.").foregroundStyle(.secondary)
                }
            }
            .frame(height: 440)
            .background(Color.primary.opacity(0.03))

            Divider()

            HStack {
                Button { model.onUseSystemPicker() } label: {
                    Text("Use macOS Picker Instead").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Cancel") { model.onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.showTitle) { model.onDone(model.chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selected.isEmpty)
            }
            .controlSize(.large)
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 820)
    }
}

struct WindowCard: View {
    let item: WindowPickerModel.Item
    let thumb: NSImage?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .padding(8)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            HStack(spacing: 6) {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(item.app).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Text(item.title.isEmpty ? "Untitled window" : item.title)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Presentation window (what the room sees in Window or App mode)

final class OutputWindow: NSWindow {
    let videoLayer = CALayer()
    let cursorLayer = CALayer()
    private let placeholder = NSTextField(labelWithString: "")

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver // above the external display's menu bar, Dock and other apps
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = .none // never capture ourselves (no feedback loops)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(videoLayer)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        cursorLayer.contentsGravity = .resize
        view.layer?.addSublayer(cursorLayer)

        placeholder.font = .systemFont(ofSize: 28, weight: .medium)
        placeholder.textColor = NSColor(white: 1, alpha: 0.35)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        contentView = view
        setPlaceholder("Waiting for content…")
    }

    func setPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
        if text != nil { videoLayer.contents = nil }
    }

    func fit(to screen: NSScreen) { setFrame(screen.frame, display: true) }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Capture

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private(set) var stream: SCStream?
    private let queue = DispatchQueue(label: "WirePlay.frames", qos: .userInteractive)
    weak var window: OutputWindow?
    var blanked = false { didSet { if blanked { window?.cursorLayer.isHidden = true } } }
    var onStopped: () -> Void = {}
    var onFailed: (Error) -> Void = { _ in }

    // The stream never captures the real pointer. WirePlay draws its own on the TV, and only
    // while the pointer is over shared content. (Switching the stream's own pointer on and off
    // reconfigures the stream, which makes the video flicker.)
    private(set) var sharedWindowIDs = Set<CGWindowID>()
    private var sharedPIDs = Set<pid_t>()          // apps shared as a whole
    private var sharedWindowOwners = Set<pid_t>()  // their menus and pop-ups count too
    private var screenRect = CGRect.null           // desktop area the frames show (global, top-left origin)
    private var contentSize = CGSize.zero          // size of that content inside each frame, in pixels
    private var cursorTimer: Timer?
    private var tick = 0
    private var overShared = false
    private var loggedFrame = false

    static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        c.width = max(2, Int(filter.contentRect.width * scale))
        c.height = max(2, Int(filter.contentRect.height * scale))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30) // plenty for slides and documents; half the work of 60
        c.queueDepth = 3
        c.showsCursor = false
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.capturesAudio = false
        return c
    }

    func apply(_ filter: SCContentFilter, windows: [SCWindow]? = nil) {
        let config = Capture.configuration(for: filter)
        if let windows { // picked in WirePlay's own chooser
            sharedWindowIDs = Set(windows.map(\.windowID))
            sharedWindowOwners = Set(windows.compactMap { $0.owningApplication?.processID })
            sharedPIDs = []
        } else if #available(macOS 15.2, *) {
            sharedWindowIDs = Set(filter.includedWindows.map(\.windowID))
            sharedWindowOwners = Set(filter.includedWindows.compactMap { $0.owningApplication?.processID })
            sharedPIDs = Set(filter.includedApplications.map(\.processID))
        }
        loggedFrame = false
        log("filter style=\(filter.style.rawValue) rect=\(filter.contentRect) → \(config.width)x\(config.height); windows=\(sharedWindowIDs.count) apps=\(sharedPIDs.count)")
        startCursorWatch()
        if let stream {
            Task {
                do { try await stream.updateContentFilter(filter); try await stream.updateConfiguration(config) }
                catch { log("update failed: \(error)") }
            }
            return
        }
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) } catch { log("addStreamOutput: \(error)"); return }
        stream = s
        SCContentSharingPicker.shared.setConfiguration(PickerSetup.configuration, for: s)
        Task {
            do {
                try await s.startCapture(); log("capture started")
                // Stopped or replaced while it was starting: don't leave an orphan capture running.
                DispatchQueue.main.async { if self.stream !== s { Task { try? await s.stopCapture() }; log("dropped a capture that was replaced while starting") } }
            } catch {
                log("startCapture failed: \(error)")
                DispatchQueue.main.async { if self.stream === s { self.stream = nil }; self.onFailed(error) }
            }
        }
    }

    func stop() {
        cursorTimer?.invalidate(); cursorTimer = nil
        window?.cursorLayer.isHidden = true
        screenRect = .null
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
        DispatchQueue.main.async { self.window?.setPlaceholder("Waiting for content…") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }

        // Crop off the letterbox padding so the shared content fills the TV, and remember where
        // on the desktop it came from so our pointer can be placed over it.
        let W = CGFloat(CVPixelBufferGetWidth(pixels)), H = CGFloat(CVPixelBufferGetHeight(pixels))
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1), size = CGSize(width: W, height: H)
        let scale = (info[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
        let content = (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        if let cr = content {
            var px = CGRect(x: cr.minX * scale, y: cr.minY * scale, width: cr.width * scale, height: cr.height * scale)
            if px.maxX > W + 2 || px.maxY > H + 2 { px = cr } // already in pixels
            px = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            if !px.isEmpty { crop = CGRect(x: px.minX / W, y: px.minY / H, width: px.width / W, height: px.height / H); size = px.size }
        }
        let screen = (info[.screenRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if !self.loggedFrame {
                self.loggedFrame = true
                log("frame \(Int(W))x\(Int(H)) contentRect=\(content.map { "\($0)" } ?? "nil") scale=\(scale) screenRect=\(screen)")
            }
            self.screenRect = screen
            self.contentSize = size
            guard !self.blanked else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            window.videoLayer.contents = surface
            window.videoLayer.contentsRect = crop
            CATransaction.commit()
            window.setPlaceholder(nil)
        }
    }

    // Called when sharing is stopped from the system's screen-sharing menu bar indicator.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.stream === stream { self.stream = nil; self.onStopped() }
        }
    }

    // MARK: Pointer

    private func startCursorWatch() {
        guard cursorTimer == nil else { return }
        tick = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updateCursor() }
        RunLoop.main.add(t, forMode: .common) // keep moving during menu tracking too
        cursorTimer = t
    }

    private func updateCursor() {
        guard let window, stream != nil else { return }
        let layer = window.cursorLayer
        if tick % 6 == 0 { overShared = pointerIsOverSharedContent() } // window list 10×/s; the pointer itself still moves at 60
        tick += 1

        guard overShared, !blanked, !screenRect.isNull, screenRect.width > 0, contentSize.width > 0,
              let p = CGEvent(source: nil)?.location, screenRect.contains(p) else {
            if !layer.isHidden { CATransaction.begin(); CATransaction.setDisableActions(true); layer.isHidden = true; CATransaction.commit() }
            return
        }
        // Where the content sits on the TV (aspect fit), then map the pointer into it.
        let b = window.videoLayer.bounds
        let fit = min(b.width / contentSize.width, b.height / contentSize.height)
        let shown = CGRect(x: b.midX - contentSize.width * fit / 2, y: b.midY - contentSize.height * fit / 2,
                           width: contentSize.width * fit, height: contentSize.height * fit)
        let k = shown.width / screenRect.width // TV points per desktop point
        let x = shown.minX + (p.x - screenRect.minX) * k
        let y = shown.maxY - (p.y - screenRect.minY) * k

        let cursor = NSCursor.currentSystem ?? .arrow
        let img = cursor.image, hot = cursor.hotSpot // hot spot is measured from the image's top-left
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if tick % 3 == 1 || layer.contents == nil { layer.contents = img }
        layer.frame = CGRect(x: x - hot.x * k, y: y - (img.size.height - hot.y) * k,
                             width: img.size.width * k, height: img.size.height * k)
        layer.isHidden = false
        CATransaction.commit()
    }

    /// Is the topmost window under the pointer one of the shared windows (or part of a shared app)?
    private func pointerIsOverSharedContent() -> Bool {
        guard let point = CGEvent(source: nil)?.location, // top-left-origin global coordinates
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list { // front to back
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.contains(point) else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if sharedWindowIDs.contains(id) || sharedPIDs.contains(pid) { return true }
            if layer != 0 {
                if sharedWindowOwners.contains(pid) { return true }                 // the shared app's menus / pop-ups
                if (w[kCGWindowOwnerName as String] as? String) == "Dock" { return false }
                continue // floating overlays (Grammarly etc.) are usually invisible and click-through
            }
            return false // another app's window is on top
        }
        return false
    }
}

enum PickerSetup {
    static var configuration: SCContentSharingPickerConfiguration {
        var c = SCContentSharingPickerConfiguration()
        // No display modes: picking the external display itself would show its empty desktop.
        c.allowedPickerModes = [.singleWindow, .multipleWindows, .singleApplication, .multipleApplications]
        c.allowsChangingSelectedContent = true
        c.excludedBundleIDs = excludedApps()
        log("picker excludes \(c.excludedBundleIDs.joined(separator: ", "))")
        return c
    }

    /// Apps the picker should ignore. Background (menu bar) apps such as Grammarly float
    /// invisible windows over other apps; the picker then thinks the pointer is over them and
    /// its "Share This Window" button collapses before it can be clicked.
    static func excludedApps() -> [String] {
        var ids: Set<String> = ["com.grammarly.ProjectLlama", "com.grammarly.ProjectLlama.Shepherd"]
        if let me = Bundle.main.bundleIdentifier { ids.insert(me) }
        let onScreenPIDs = Set(((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                                 as? [[String: Any]]) ?? []).compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .regular {
            guard let id = app.bundleIdentifier, onScreenPIDs.contains(app.processIdentifier),
                  !id.hasPrefix("com.apple.") else { continue } // leave macOS's own UI alone
            ids.insert(id)
        }
        return ids.sorted()
    }
}


// MARK: - Icon

/// A monitor with an HDMI plug in its bottom edge: the AirPlay symbol, but wired.
/// Used for the menu bar icon and (via `--make-icon`) the app icon.
enum Glyph {
    static func draw(in r: NSRect, color: NSColor, slot: NSColor?, screenFill: NSColor? = nil) {
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: r.minX + x * r.width, y: r.minY + y * r.height, width: w * r.width, height: h * r.height)
        }
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        guard let ctx = NSGraphicsContext.current else { return }

        let lw = 0.08 * r.width
        let screen = NSBezierPath(roundedRect: R(0.04, 0.34, 0.92, 0.60).insetBy(dx: lw / 2, dy: lw / 2),
                                  xRadius: 0.08 * r.width, yRadius: 0.08 * r.width)
        screen.lineWidth = lw
        if let screenFill { // inside the outline's inner edge only
            screenFill.setFill()
            NSBezierPath(roundedRect: R(0.04, 0.34, 0.92, 0.60).insetBy(dx: lw, dy: lw),
                         xRadius: 0.04 * r.width, yRadius: 0.04 * r.width).fill()
        }

        // Monitor outline, with a gap in the bottom edge where the plug goes in.
        ctx.saveGraphicsState()
        let clip = NSBezierPath(rect: r)
        clip.append(NSBezierPath(rect: R(0.27, 0.18, 0.46, 0.30)))
        clip.windingRule = .evenOdd
        clip.addClip()
        color.setStroke(); screen.stroke()
        ctx.restoreGraphicsState()

        color.setFill()
        // HDMI plug head: a wide rectangle with chamfered bottom corners.
        let head = NSBezierPath()
        head.move(to: P(0.30, 0.58)); head.line(to: P(0.70, 0.58)); head.line(to: P(0.70, 0.47))
        head.line(to: P(0.62, 0.38)); head.line(to: P(0.38, 0.38)); head.line(to: P(0.30, 0.47)); head.close()
        head.fill()
        // Boot (separated from the metal head by a small gap) and cable.
        NSBezierPath(roundedRect: R(0.37, 0.15, 0.26, 0.195), xRadius: 0.03 * r.width, yRadius: 0.03 * r.width).fill()
        NSBezierPath(rect: R(0.455, 0.0, 0.09, 0.16)).fill()

        // The contact slot inside the plug head.
        let slotRect = NSBezierPath(roundedRect: R(0.36, 0.475, 0.28, 0.05), xRadius: 0.02 * r.width, yRadius: 0.02 * r.width)
        if let slot { slot.setFill(); slotRect.fill() }
        else { ctx.saveGraphicsState(); ctx.compositingOperation = .clear; slotRect.fill(); ctx.restoreGraphicsState() }
    }

    static var menuBarImage: NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            draw(in: NSRect(x: 1.5, y: 1, width: 17, height: 16), color: .black, slot: nil); return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "WirePlay"
        return img
    }

    /// Writes AppIcon.iconset PNGs into `dir`.
    static func writeIconset(to dir: String) {
        let sizes: [(Int, String)] = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                                      (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
        for (px, name) in sizes {
            let side = CGFloat(px)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let tile = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.098, dy: side * 0.098)
            let bg = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.56, blue: 1.0, alpha: 1),
                       ending: NSColor(calibratedRed: 0.06, green: 0.24, blue: 0.72, alpha: 1))!.draw(in: bg, angle: -90)
            let g = tile.insetBy(dx: tile.width * 0.17, dy: tile.width * 0.17)
            draw(in: g, color: .white, slot: NSColor(calibratedRed: 0.1, green: 0.32, blue: 0.82, alpha: 1),
                 screenFill: NSColor(white: 1, alpha: 0.16))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }
}

// MARK: - Accessibility helpers (for driving Control Center's Screen Mirroring)

enum AX {
    static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as AnyObject?
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attribute(el, name) as? String }
    static func children(_ el: AXUIElement) -> [AXUIElement] { (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }
    static func title(_ el: AXUIElement) -> String { string(el, kAXTitleAttribute) ?? "" }
    static func identifier(_ el: AXUIElement) -> String { string(el, "AXIdentifier") ?? "" }
    /// Every human-readable string attached to an element.
    static func labels(_ el: AXUIElement) -> [String] {
        var out = [title(el), string(el, kAXDescriptionAttribute) ?? "", identifier(el), string(el, kAXHelpAttribute) ?? ""]
        if let v = attribute(el, kAXValueAttribute) as? String { out.append(v) }
        return out.filter { !$0.isEmpty }
    }
    @discardableResult
    static func press(_ el: AXUIElement) -> Bool { AXUIElementPerformAction(el, kAXPressAction as CFString) == .success }

    /// Depth-first walk with a node budget; `visit` returns true to stop.
    static func walk(_ root: AXUIElement, maxNodes: Int = 3000, maxDepth: Int = 30, _ visit: (AXUIElement, Int) -> Bool) {
        var budget = maxNodes
        func go(_ el: AXUIElement, _ depth: Int) -> Bool {
            guard budget > 0, depth <= maxDepth else { return false }
            budget -= 1
            if visit(el, depth) { return true }
            for child in children(el) where go(child, depth + 1) { return true }
            return false
        }
        _ = go(root, 0)
    }

    static func first(in root: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(root) { el, _ in if match(el) { found = el; return true }; return false }
        return found
    }

    static func dump(_ root: AXUIElement, maxNodes: Int = 600) -> String {
        var lines: [String] = []
        walk(root, maxNodes: maxNodes) { el, depth in
            let value = attribute(el, kAXValueAttribute).map { "\($0)" } ?? ""
            let actions: [String] = {
                var names: CFArray?
                return AXUIElementCopyActionNames(el, &names) == .success ? ((names as? [String]) ?? []) : []
            }()
            lines.append(String(repeating: "  ", count: depth)
                + "\(role(el)) [\(string(el, kAXSubroleAttribute) ?? "")] title=\"\(title(el))\" desc=\"\(string(el, kAXDescriptionAttribute) ?? "")\""
                + " id=\"\(identifier(el))\" value=\"\(value.prefix(40))\" actions=\(actions.filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" })")
            return false
        }
        return lines.joined(separator: "\n")
    }
}

/// Finds Control Center and its windows. On macOS 26+ the menu bar items live in MenuBarAgent,
/// while Control Center's own panel (and its Screen Mirroring list) belong to ControlCenter.
enum ControlCenterUI {
    static let hostNames = ["ControlCenter", "MenuBarAgent"]

    static func hosts() -> [(name: String, app: AXUIElement)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.executableURL?.lastPathComponent, hostNames.contains(name) else { return nil }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 2)
            return (name, el)
        }
    }

    /// The Control Center item in the menu bar.
    static func menuBarItem() -> AXUIElement? {
        for (_, app) in hosts() {
            var roots: [AXUIElement] = []
            for attr in ["AXExtrasMenuBar", kAXMenuBarAttribute] {
                if let v = AX.attribute(app, attr), CFGetTypeID(v) == AXUIElementGetTypeID() { roots.append(v as! AXUIElement) }
            }
            if roots.isEmpty { roots = AX.children(app) }
            for root in roots {
                if let item = AX.first(in: root, where: { el in
                    AX.role(el) == kAXMenuBarItemRole
                        && AX.labels(el).contains { $0.lowercased().contains("controlcenter") || $0.lowercased().contains("control center") }
                }) { return item }
            }
        }
        return nil
    }

    static func windows() -> [(host: String, window: AXUIElement)] {
        hosts().flatMap { host in AX.children(host.app).filter { AX.role($0) == kAXWindowRole }.map { (host.name, $0) } }
    }
}

/// `WirePlay --dump-airplay`: opens Control Center and its Screen Mirroring list, writes what
/// Accessibility sees to ~/Library/Logs/WirePlay-airplay-ax.txt, and closes them. Connects nothing.
enum AirPlayProbe {
    static func run() {
        var out = ["WirePlay \(appVersion) Screen Mirroring probe \(Date())", "Accessibility trusted: \(AXIsProcessTrusted())"]
        defer {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WirePlay-airplay-ax.txt")
            try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard AXIsProcessTrusted() else { out.append("Not trusted — grant Accessibility to WirePlay first."); return }
        guard let cc = ControlCenterUI.menuBarItem() else {
            out.append("Control Center menu bar item not found. Hosts and their trees:")
            for (name, app) in ControlCenterUI.hosts() { out.append("== \(name)"); out.append(AX.dump(app, maxNodes: 200)) }
            return
        }
        out.append("Control Center item: \(AX.labels(cc))")
        AX.press(cc)
        Thread.sleep(forTimeInterval: 1.2)
        for (host, w) in ControlCenterUI.windows() { out.append("== Control Center open — \(host) window"); out.append(AX.dump(w)) }

        // The Screen Mirroring tile; its list of receivers opens inside Control Center.
        let tile = ControlCenterUI.windows().lazy.compactMap { pair in
            AX.first(in: pair.window) { el in AX.labels(el).contains { $0.lowercased().contains("screen mirroring") || $0.lowercased().contains("screenmirroring") } }
        }.first
        if let tile {
            out.append("Screen Mirroring tile: role=\(AX.role(tile)) labels=\(AX.labels(tile))")
            AX.press(tile)
            Thread.sleep(forTimeInterval: 1.5)
            for (host, w) in ControlCenterUI.windows() { out.append("== Screen Mirroring open — \(host) window"); out.append(AX.dump(w, maxNodes: 900)) }
        } else {
            out.append("Screen Mirroring tile not found")
        }
        ScreenMirroring.close()
        out.append("Receivers via the driver: \((try? ScreenMirroring.listedReceivers())?.joined(separator: ", ") ?? "failed")")
        out.append("Windows after closing: \(ControlCenterUI.windows().count)")
    }
}

// MARK: - AirPlay
//
// There is no public API for starting AirPlay screen sharing, so WirePlay drives the same
// Screen Mirroring list you'd click in the menu bar or Control Center (through Accessibility),
// asks for an extended display, and then treats that AirPlay display exactly like an HDMI
// one: black cover, WirePlay's own window grid, pointer fence.

/// Finds AirPlay receivers on the network (Bonjour), so the menu can list them without
/// opening Control Center.
final class AirPlayBrowser: ObservableObject {
    @Published private(set) var receivers: [String] = []
    private var browser: NWBrowser?
    private let ownName = Host.current().localizedName ?? ""

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case let .service(name, _, _, _) = r.endpoint { return name }
                return nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let first = self.receivers.isEmpty
                self.receivers = Array(Set(names)).filter { $0 != self.ownName }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                if first && !self.receivers.isEmpty { log("AirPlay: found \(self.receivers.count) receivers") }
            }
        }
        b.stateUpdateHandler = { state in if case .failed(let e) = state { log("AirPlay browse failed: \(e)") } }
        b.start(queue: .main)
        browser = b
    }
}

/// Drives macOS's Screen Mirroring list. All calls block (they wait for the UI), so run them
/// off the main thread.
enum ScreenMirroring {
    enum Failure: LocalizedError {
        case notTrusted, listNotFound, receiverNotFound(String), pressFailed
        var errorDescription: String? {
            switch self {
            case .notTrusted: return "WirePlay needs Accessibility permission to start AirPlay."
            case .listNotFound: return "Couldn’t open the Screen Mirroring list."
            case .receiverNotFound(let n): return "“\(n)” isn’t in the Screen Mirroring list right now."
            case .pressFailed: return "macOS didn’t accept the click."
            }
        }
    }

    private static let listID = "screen-mirroring-device-list"
    private static let devicePrefix = "screen-mirroring-device-"

    private static func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; Thread.sleep(forTimeInterval: 0.1) }
        return done()
    }

    /// The Screen Mirroring item in the menu bar (if the user keeps it there).
    private static func menuExtra() -> AXUIElement? {
        for (_, app) in ControlCenterUI.hosts() {
            if let el = AX.first(in: app, where: { AX.identifier($0) == "com.apple.menuextra.screen-mirroring" }) { return el }
        }
        return nil
    }

    /// The open Screen Mirroring list, wherever it's hosted.
    private static func listWindow() -> AXUIElement? {
        ControlCenterUI.windows().first { pair in AX.first(in: pair.window) { AX.identifier($0) == listID } != nil }?.window
    }

    private static func openList() throws -> AXUIElement {
        if let w = listWindow() { return w }
        if let item = menuExtra() {
            AX.press(item)
        } else if let cc = ControlCenterUI.menuBarItem() {
            // Not in the menu bar: open Control Center and its Screen Mirroring tile.
            AX.press(cc)
            var tile: AXUIElement?
            _ = wait(2) {
                tile = ControlCenterUI.windows().lazy.compactMap { pair in
                    AX.first(in: pair.window) { el in
                        AX.role(el) != kAXMenuBarItemRole && AX.labels(el).contains { $0.lowercased().contains("screen mirroring") }
                    }
                }.first
                return tile != nil
            }
            guard let tile else { throw Failure.listNotFound }
            AX.press(tile)
        } else {
            throw Failure.listNotFound
        }
        var w: AXUIElement?
        guard wait(3, until: { w = listWindow(); return w != nil }), let w else { throw Failure.listNotFound }
        return w
    }

    static func close() {
        guard listWindow() != nil else { return }
        if let item = menuExtra() { AX.press(item) } else if let cc = ControlCenterUI.menuBarItem() { AX.press(cc) }
        _ = wait(1.5) { listWindow() == nil }
    }

    private struct Device { let name: String; let toggle: AXUIElement; let id: String; let on: Bool }

    private static func devices(in w: AXUIElement) -> [Device] {
        var out: [Device] = []
        AX.walk(w) { el, _ in
            let id = AX.identifier(el)
            if AX.role(el) == kAXCheckBoxRole, id.hasPrefix(devicePrefix) {
                let on = (AX.attribute(el, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
                out.append(Device(name: AX.string(el, kAXDescriptionAttribute) ?? "", toggle: el, id: id, on: on))
            }
            return false
        }
        return out
    }

    private static func device(named name: String, in w: AXUIElement) -> Device? {
        if let d = devices(in: w).first(where: { $0.name == name }) { return d }
        // Not among the first few: expand "Show More" and look again.
        if let more = AX.first(in: w, where: { AX.role($0) == "AXDisclosureTriangle" }) {
            AX.press(more)
            var found: Device?
            _ = wait(1.5) { found = devices(in: w).first { $0.name == name }; return found != nil }
            return found
        }
        return nil
    }

    /// Names macOS currently offers in the list (for diagnostics).
    static func listedReceivers() throws -> [String] {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        let w = try openList(); defer { close() }
        return devices(in: w).map { "\($0.name)\($0.on ? " (on)" : "")" }
    }

    /// Starts AirPlay to `name` and asks for an extended display. Returns once macOS has been
    /// told; the display itself shows up a few seconds later.
    static func connect(_ name: String) throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        let w = try openList()
        defer { close() }
        guard let d = device(named: name, in: w) else { throw Failure.receiverNotFound(name) }
        if d.on { log("AirPlay: \(name) already connected"); return }
        guard AX.press(d.toggle) else { throw Failure.pressFailed }
        log("AirPlay: asked macOS to connect to \(name)")
        answerShowSheet(for: name)
    }

    /// macOS may ask "What do you want to show on …?" (unless a default is set for that
    /// receiver). Pick Extended Display; WirePlay then shows only the chosen windows on it.
    private static func answerShowSheet(for name: String) {
        var sheet: AXUIElement?
        let appeared = wait(6) {
            sheet = allWindows().first { w in
                AX.first(in: w) { el in AX.labels(el).contains { $0.contains("What do you want to show") } } != nil
            }
            return sheet != nil
        }
        guard appeared, let sheet else { log("AirPlay: no 'What do you want to show' sheet (a default may be set)"); return }
        log("AirPlay sheet:\n" + AX.dump(sheet, maxNodes: 200))
        if let card = AX.first(in: sheet, where: { el in AX.labels(el).contains { $0 == "Extended Display" } && AX.press(el) }) {
            _ = card
            Thread.sleep(forTimeInterval: 0.4)
        } else {
            log("AirPlay: Extended Display option not found in the sheet")
        }
        // Confirm with the sheet's default button ("Use as Extended Display" or similar).
        if let def = AX.attribute(sheet, kAXDefaultButtonAttribute), CFGetTypeID(def) == AXUIElementGetTypeID() {
            AX.press(def as! AXUIElement)
            log("AirPlay: confirmed the sheet")
        } else if let button = AX.first(in: sheet, where: { el in
            AX.role(el) == kAXButtonRole && AX.labels(el).contains { $0.localizedCaseInsensitiveContains("extend") }
        }) {
            AX.press(button)
            log("AirPlay: confirmed the sheet (\(AX.labels(button)))")
        } else {
            log("AirPlay: couldn't find the sheet's confirm button")
        }
    }

    /// Windows of every app that might host the AirPlay sheet.
    private static func allWindows() -> [AXUIElement] {
        let names: Set<String> = ["AirPlayUIAgent", "ControlCenter", "MenuBarAgent", "SystemUIServer", "WindowManager"]
        return NSWorkspace.shared.runningApplications.flatMap { app -> [AXUIElement] in
            guard let n = app.executableURL?.lastPathComponent, names.contains(n) else { return [] }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 1)
            return AX.children(el).filter { AX.role($0) == kAXWindowRole }
        }
    }

    /// Stops AirPlay to `name` (its "Stop Mirroring" button in the list).
    static func disconnect(_ name: String) throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        let w = try openList()
        defer { close() }
        guard let d = device(named: name, in: w) else { throw Failure.receiverNotFound(name) }
        if let stop = AX.first(in: w, where: { el in
            AX.role(el) == kAXButtonRole && AX.identifier(el) == d.id && (AX.string(el, kAXDescriptionAttribute) ?? "").contains("Stop")
        }) {
            AX.press(stop)
        } else if d.on {
            AX.press(d.toggle)
        }
        log("AirPlay: disconnected \(name)")
    }
}

// MARK: AirPlay receiver picker

final class AirPlayPickerModel: ObservableObject {
    @Published var connecting: String?
    @Published var error: String?
    let browser: AirPlayBrowser
    var onPick: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    init(browser: AirPlayBrowser) { self.browser = browser }
}

struct AirPlayPickerView: View {
    @ObservedObject var model: AirPlayPickerModel
    @ObservedObject var browser: AirPlayBrowser

    init(model: AirPlayPickerModel) { self.model = model; self.browser = model.browser }

    var body: some View {
        VStack(spacing: 0) {
            Text("AirPlay to…").font(.system(size: 17, weight: .semibold)).padding(.top, 22)
            Text("Pick a TV. WirePlay connects, blanks it, and lets you choose which windows to show.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
            ZStack {
                List(browser.receivers, id: \.self) { name in
                    Button { model.onPick(name) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tv").frame(width: 22).foregroundStyle(Color.accentColor)
                            Text(name)
                            Spacer()
                            if model.connecting == name { ProgressView().controlSize(.small) }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.connecting != nil)
                }
                if browser.receivers.isEmpty { ProgressView("Looking for AirPlay TVs…") }
            }
            .frame(height: 300)
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 8)
            }
            Divider().padding(.top, 10)
            HStack {
                Spacer()
                Button("Cancel") { model.onCancel() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.large).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(width: 420)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SCContentSharingPickerObserver {
    private var statusItem: NSStatusItem!
    private let store = Store.shared
    private var known = Set<CGDirectDisplayID>()
    private var chooser: NSPanel?
    private var windowPicker: NSPanel?
    private var settings: NSWindow?
    private var output: OutputWindow?
    private let capture = Capture()
    private let fence = PointerFence()
    private var rescueTimer: Timer?
    private let rescueQueue = DispatchQueue(label: "WirePlay.rescue", qos: .utility)
    private var rescueBusy = false
    private var target: ExternalDisplay?        // display currently presenting windows
    private var modes: [CGDirectDisplayID: ShowMode] = [:]
    private var rescanPending = false
    /// Bumped on every mode change; async work checks it so a late callback can't undo a newer choice.
    private var generation = 0
    /// Displays waiting for their chooser when several connect at once.
    private var pendingChoosers: [ExternalDisplay] = []
    private var chooserDisplay: ExternalDisplay?
    /// The presentation display dropped out while showing windows; resume if it's back soon.
    private var lostKey: String?
    private var graceTimer: Timer?
    // AirPlay
    private let airPlay = AirPlayBrowser()
    private let airPlayQueue = DispatchQueue(label: "WirePlay.airplay")
    private var airPlayPicker: NSPanel?
    private var airPlayPickerModel: AirPlayPickerModel?
    private var pendingAirPlay: (name: String, until: Date)? // asked macOS to connect; display not here yet
    private var airPlayReceiver: String?                       // receiver behind the current target

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch \(appVersion) from \(Bundle.main.bundlePath)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Glyph.menuBarImage
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu

        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = PickerSetup.configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        // Only active while presenting: an active picker puts macOS's green screen-sharing
        // indicator in the menu bar.

        capture.onStopped = { [weak self] in self?.endWindowMode(showDesktop: false) }
        capture.onFailed = { [weak self] error in
            let failed = self?.target
            self?.endWindowMode(showDesktop: true)
            let a = NSAlert()
            a.messageText = "macOS didn’t allow WirePlay to show that window"
            a.informativeText = "If you were asked for permission, allow it and choose the window again. Otherwise open System Settings → Privacy & Security → Screen & System Audio Recording and turn on WirePlay.\n\n\(error.localizedDescription)"
            a.addButton(withTitle: "Try Again"); a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn:
                let online = ExternalDisplay.online().filter { !$0.isVirtual }
                if let d = online.first(where: { $0 == failed }) ?? online.first { self?.apply(.windowOrApp, to: d) }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            default: break
            }
        }
        store.onFenceChange = { [weak self] in self?.updateFence() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRescan()
        }
        // Mirroring changes don't always change NSScreen.screens; catch them here too.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.scheduleRescan() }
        }, nil)

        // Fallback path from the Control Center button, if it couldn't open the wireplay:// link.
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.ben.WirePlay.choose"), object: nil, queue: .main) { [weak self] _ in
            self?.handle("choose")
        }

        keepLoginItemCurrent()
        airPlay.start()
        rescan()
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    /// The login item points at the app's path. If the app was moved (e.g. ~/Applications to
    /// /Applications), register it again so "Launch at login" keeps working.
    private func keepLoginItemCurrent() {
        let service = SMAppService.mainApp
        if service.status == .enabled { UserDefaults.standard.set(true, forKey: "launchAtLogin") }
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        do { try service.register(); log("login item registered for \(Bundle.main.bundlePath)") }
        catch { log("login item: \(error)") }
    }

    func applicationWillTerminate(_ note: Notification) {
        fence.stop()
        capture.stop()
        SCContentSharingPicker.shared.isActive = false
    }

    // Reopening the app (double-click in Finder) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: wireplay:// links (from the Control Center button)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "wireplay" { handle(url.host ?? "choose") }
    }

    private func handle(_ action: String) {
        log("link: \(action)")
        switch action {
        case "settings":
            showSettings()
        default: // "choose" — the Control Center button
            if target != nil {
                presentPicker() // already showing (or choosing) windows: go straight to adding/removing them
            } else if let d = ExternalDisplay.online().first(where: { !$0.isVirtual }) {
                showChooser(for: d)
            } else {
                showAirPlayPicker() // nothing plugged in: AirPlay to a TV instead
            }
        }
    }

    // MARK: Display tracking

    func scheduleRescan() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.rescanPending = false; self?.rescan() }
    }

    private func rescan() {
        let displays = ExternalDisplay.online()
        let ids = Set(displays.map(\.id))

        if let t = target {
            if !ids.contains(t.id) {
                if airPlayReceiver != nil { log("AirPlay display went away"); airPlayReceiver = nil; endWindowMode(showDesktop: false) }
                else if lostKey == nil && capture.stream != nil { beginGrace(for: t) }
                else if lostKey == nil { log("presenting display gone"); endWindowMode(showDesktop: false) }
            } else if let screen = t.screen { output?.fit(to: screen); updateFence() }
        }
        for gone in known.subtracting(ids) { modes[gone] = nil }

        for d in displays where !d.isVirtual { store.remember(d.key, name: d.screen?.localizedName) }
        store.connectedKeys = Set(displays.map(\.key))

        for d in displays where !known.contains(d.id) {
            log("connected \(d.name) id=\(d.id) key=\(d.key) mirrored=\(d.isMirrored)")
            // The receiver we just asked macOS to AirPlay to. Match it by name; fall back to the
            // first new virtual display in case macOS names it differently.
            if let pending = pendingAirPlay, Date() < pending.until,
               d.airPlayReceiver == pending.name || (d.airPlayReceiver == nil && d.isVirtual) {
                airPlayConnected(pending.name, display: d); continue
            }
            if d.isVirtual { continue }
            if let lostKey, d.key == lostKey { resume(on: d); continue }
            let rule = store.rule(for: d.key)
            if rule == .ignore { log("ignoring \(d.name)"); continue }
            if let mode = rule.mode { apply(mode, to: d) } else { showChooser(for: d, queued: true) }
        }
        known = ids
    }

    /// A cable blip or a TV input switch shouldn't end the presentation: keep capturing for a
    /// few seconds and pick up where we were if the same monitor comes back.
    private func beginGrace(for display: ExternalDisplay) {
        log("presenting display dropped out; waiting 15 s for it to come back")
        lostKey = display.key
        output?.orderOut(nil)
        updateFence() // no screen: pointer fence and window rescue pause
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            log("display didn't come back; stopping")
            self?.endWindowMode(showDesktop: false)
        }
    }

    private func resume(on display: ExternalDisplay) {
        log("display is back; resuming")
        graceTimer?.invalidate(); graceTimer = nil
        lostKey = nil
        target = display
        modes[display.id] = .windowOrApp
        setMirroring(display.id, on: false)
        let gen = generation
        waitForScreen(display, attempts: 40) { [weak self] screen in
            guard let self, gen == self.generation, self.target == display, let screen else { return }
            self.output?.fit(to: screen)
            self.output?.orderFrontRegardless()
            self.updateFence()
        }
    }

    /// Window or App needs a screen other than the presentation display (lid closed + TV only has none).
    private func hasOtherScreen(than display: ExternalDisplay) -> Bool {
        NSScreen.screens.contains { $0.displayID != display.id }
    }

    // MARK: Windows

    // MARK: AirPlay

    @objc func showAirPlayPicker() {
        airPlayPicker?.close()
        let model = AirPlayPickerModel(browser: airPlay)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AirPlayPickerView(model: model))
        model.onPick = { [weak self] name in self?.connectAirPlay(name) }
        model.onCancel = { [weak self] in self?.closeAirPlayPicker() }
        panel.setContentSize(panel.contentView!.fittingSize)
        place(panel, yOffset: 40)
        airPlayPicker = panel
        airPlayPickerModel = model
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeAirPlayPicker() {
        airPlayPicker?.close(); airPlayPicker = nil; airPlayPickerModel = nil
    }

    @objc private func airPlayMenuPick(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { connectAirPlay(name) }
    }

    /// Ask macOS (via the Screen Mirroring list) to AirPlay to `name` as an extended display.
    func connectAirPlay(_ name: String) {
        guard AXIsProcessTrusted() else {
            let a = NSAlert()
            a.messageText = "Allow WirePlay to start AirPlay"
            a.informativeText = "macOS has no way for apps to start AirPlay directly, so WirePlay uses the Screen Mirroring menu for you. That needs Accessibility permission: turn on WirePlay in System Settings › Privacy & Security › Accessibility, then try again."
            a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return
        }
        if target != nil { endWindowMode(showDesktop: false) } // one presentation at a time
        log("AirPlay: connecting to \(name)")
        airPlayPickerModel?.connecting = name
        airPlayPickerModel?.error = nil
        pendingAirPlay = (name, Date().addingTimeInterval(25))
        airPlayQueue.async { [weak self] in
            do { try ScreenMirroring.connect(name) }
            catch {
                log("AirPlay: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.airPlayFailed(name, error.localizedDescription) }
            }
        }
        // If no display turns up, say so instead of waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.pendingAirPlay?.name == name else { return }
            self.airPlayFailed(name, "“\(name)” didn’t connect. Is it on, and on the same network?")
        }
    }

    private func airPlayFailed(_ name: String, _ message: String) {
        guard pendingAirPlay?.name == name else { return }
        pendingAirPlay = nil
        if let model = airPlayPickerModel {
            model.connecting = nil; model.error = message
        } else {
            let a = NSAlert(); a.messageText = "AirPlay to “\(name)” didn’t start"; a.informativeText = message
            NSApp.activate(ignoringOtherApps: true); a.runModal()
        }
    }

    /// The AirPlay display appeared: cover it and open the window grid, like Window or App.
    private func airPlayConnected(_ name: String, display: ExternalDisplay) {
        log("AirPlay: \(name) connected as display \(display.id)")
        pendingAirPlay = nil
        airPlayNames[display.id] = name
        airPlayReceiver = name
        closeAirPlayPicker()
        apply(.windowOrApp, to: display)
    }

    @objc private func stopAirPlay() {
        guard let name = airPlayReceiver else { return }
        airPlayReceiver = nil
        endWindowMode(showDesktop: false)
        airPlayQueue.async {
            do { try ScreenMirroring.disconnect(name) } catch { log("AirPlay: stop failed: \(error.localizedDescription)") }
        }
    }

    /// `queued`: from a new connection. If a chooser or the window grid is already up, wait
    /// for it instead of replacing it, so each display that connected gets asked.
    func showChooser(for display: ExternalDisplay, queued: Bool = false) {
        if queued && (chooser != nil || windowPicker != nil) {
            if chooserDisplay != display && !pendingChoosers.contains(display) {
                pendingChoosers.append(display)
                log("queued the chooser for \(display.name)")
            }
            return
        }
        chooser?.close()
        chooserDisplay = display
        let model = ChooserModel(displayName: display.name, initial: modes[display.id] ?? .windowOrApp,
                                 showingWindows: target == display && capture.stream != nil,
                                 windowModeAvailable: hasOtherScreen(than: display))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ChooserView(model: model))
        model.onDone = { [weak self, weak panel] result in
            panel?.close()
            guard let self else { return }
            self.chooser = nil
            self.chooserDisplay = nil
            defer { self.showNextChooserSoon() }
            switch result {
            case .cancel: break
            case .ignore:
                self.store.setRule(.ignore, for: display.key, name: display.name)
                if self.target == display { self.endWindowMode(showDesktop: true) }
            case .show(let mode, let remember):
                if remember { self.store.setRule(Rule(mode), for: display.key, name: display.name) }
                self.apply(mode, to: display)
            }
        }
        panel.setContentSize(panel.contentView!.fittingSize)
        place(panel, yOffset: 80, avoiding: display.id)
        chooser = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Show the next waiting chooser once nothing else is on screen (after the current mode has
    /// had a moment to open its window grid).
    private func showNextChooserSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.chooser == nil, self.windowPicker == nil else { return }
            let online = Set(ExternalDisplay.online().map(\.id))
            while !self.pendingChoosers.isEmpty {
                let next = self.pendingChoosers.removeFirst()
                if online.contains(next.id) { self.showChooser(for: next); return }
            }
        }
    }

    @objc func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "WirePlay Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.setContentSize(w.contentView!.fittingSize)
            settings = w
            place(w, yOffset: 0)
        }
        store.axTrusted = AXIsProcessTrusted()
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    /// Keep our windows on the laptop screen, where the presenter is looking; never on the TV
    /// (with the lid closed, NSScreen.main can be the TV, under the black cover).
    private func place(_ w: NSWindow, yOffset: CGFloat, avoiding: CGDirectDisplayID? = nil) {
        let avoid = Set([avoiding, target?.id].compactMap { $0 })
        let home = NSScreen.screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
            ?? NSScreen.screens.first { !avoid.contains($0.displayID ?? 0) }
            ?? NSScreen.main
        if let f = home?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2 + yOffset))
        }
    }

    // MARK: Modes

    func apply(_ mode: ShowMode, to display: ExternalDisplay) {
        log("apply \(mode.rawValue) to \(display.name)")
        generation += 1
        modes[display.id] = mode
        switch mode {
        case .entireScreen:
            if target == display { endWindowMode(showDesktop: false) }
            if !setMirroring(display.id, on: true) { mirroringFailed(display, on: true) }
        case .extendedDisplay:
            if target == display { endWindowMode(showDesktop: true) }
            if !setMirroring(display.id, on: false) { mirroringFailed(display, on: false) }
        case .windowOrApp:
            guard hasOtherScreen(than: display) else {
                log("Window or App needs another screen; \(display.name) is the only one")
                modes[display.id] = nil
                let a = NSAlert()
                a.messageText = "Window or App needs your Mac’s own screen"
                a.informativeText = "“\(display.name)” is the only screen right now (is the lid closed?). Open the lid, or choose Entire Screen instead."
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
                return
            }
            if !setMirroring(display.id, on: false) { mirroringFailed(display, on: false); return }
            let gen = generation
            waitForScreen(display, attempts: 40) { [weak self] screen in
                // A newer choice (or a disconnect) since this started: leave it alone.
                guard let self, gen == self.generation, self.modes[display.id] == .windowOrApp else { return }
                guard let screen else { log("no NSScreen for \(display.id)"); return }
                self.beginWindowMode(on: display, screen: screen)
            }
        }
    }

    private func mirroringFailed(_ display: ExternalDisplay, on: Bool) {
        let a = NSAlert()
        a.messageText = on ? "Couldn’t mirror to “\(display.name)”" : "Couldn’t switch “\(display.name)” out of mirroring"
        a.informativeText = "macOS didn’t accept the display change. Try again, or change it in System Settings › Displays."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// After un-mirroring, the display takes a moment to appear as its own NSScreen.
    private func waitForScreen(_ d: ExternalDisplay, attempts: Int, then: @escaping (NSScreen?) -> Void) {
        if let s = d.screen { then(s); return }
        guard attempts > 0 else { then(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForScreen(d, attempts: attempts - 1, then: then) }
    }

    private func beginWindowMode(on display: ExternalDisplay, screen: NSScreen) {
        if target != display { endWindowMode(showDesktop: false) }
        target = display
        if output == nil {
            let w = OutputWindow(screen: screen)
            output = w
            capture.window = w
        }
        output?.fit(to: screen)
        output?.orderFrontRegardless()
        updateFence()
        presentPicker()
    }

    private func presentPicker() {
        if store.useSystemPicker { presentSystemPicker() } else { showWindowPicker() }
    }

    private func showWindowPicker() {
        guard let t = target else { return }
        guard CGPreflightScreenCaptureAccess() else { askForScreenRecording(); return }
        windowPicker?.close()
        let model = WindowPickerModel(displayName: t.name, selected: capture.stream != nil ? capture.sharedWindowIDs : [])
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WindowPickerView(model: model))
        model.onDone = { [weak self, weak panel] windows in
            panel?.close()
            guard let self else { return }
            self.windowPicker = nil
            defer { self.showNextChooserSoon() }
            guard let windows, !windows.isEmpty else {
                log("window chooser cancelled")
                if self.capture.stream == nil { self.endWindowMode(showDesktop: true) }
                return
            }
            self.share(windows)
        }
        model.onUseSystemPicker = { [weak self, weak panel] in
            panel?.close(); self?.windowPicker = nil; self?.presentSystemPicker()
        }
        panel.setContentSize(panel.contentView!.fittingSize)
        place(panel, yOffset: 40, avoiding: t.id)
        windowPicker = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let excluded = Set(PickerSetup.excludedApps())
        let tv = CGDisplayBounds(t.id)
        Task { @MainActor in await model.load(excludingBundleIDs: excluded, excludingArea: tv) }
    }

    /// One window is captured on its own (it can even be partly covered). Several windows are
    /// shown where they sit on the Mac's screen, like AirPlay does.
    private func share(_ windows: [SCWindow]) {
        log("sharing \(windows.count) window(s): \(windows.map { $0.owningApplication?.applicationName ?? "?" }.joined(separator: ", "))")
        if windows.count == 1 {
            capture.apply(SCContentFilter(desktopIndependentWindow: windows[0]), windows: windows)
            return
        }
        let gen = generation, display = target
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                // Mode changed or presentation ended while we waited: drop this.
                guard gen == self.generation, self.target == display, display != nil else { log("share dropped (mode changed)"); return }
                let home = self.target.map { primaryDisplayID(excluding: $0.id) } ?? CGMainDisplayID()
                // The display holding most of the chosen windows (normally the MacBook's).
                let display = content.displays.max { a, b in
                    windows.filter { a.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
                        < windows.filter { b.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
                } ?? content.displays.first { $0.displayID == home }
                guard let display else { log("no display for windows"); return }
                self.capture.apply(SCContentFilter(display: display, including: windows), windows: windows)
            } catch {
                log("share failed: \(error)")
            }
        }
    }

    private func askForScreenRecording() {
        let a = NSAlert()
        a.messageText = "Allow WirePlay to see your windows"
        a.informativeText = "To list your windows with previews, WirePlay needs Screen Recording permission. Turn on WirePlay in System Settings → Privacy & Security → Screen & System Audio Recording (macOS may ask to reopen WirePlay).\n\nOr use the macOS picker, which doesn’t need permission."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Use macOS Picker")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess() // adds WirePlay to that list
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            endWindowMode(showDesktop: true)
        case .alertSecondButtonReturn:
            presentSystemPicker()
        default:
            endWindowMode(showDesktop: true)
        }
    }

    private func presentSystemPicker() {
        let picker = SCContentSharingPicker.shared
        let config = PickerSetup.configuration // refreshed each time: which overlay apps are running changes
        picker.defaultConfiguration = config
        if let s = capture.stream { picker.setConfiguration(config, for: s) }
        SCContentSharingPicker.shared.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        if let s = capture.stream { SCContentSharingPicker.shared.present(for: s) }
        else { SCContentSharingPicker.shared.present() }
    }

    private func endWindowMode(showDesktop: Bool) {
        // An AirPlay TV left as a bare extended desktop would show your desktop to the room:
        // disconnect AirPlay instead.
        if showDesktop, let name = airPlayReceiver {
            airPlayReceiver = nil
            airPlayQueue.async {
                do { try ScreenMirroring.disconnect(name) } catch { log("AirPlay: stop failed: \(error.localizedDescription)") }
            }
        }
        generation += 1
        graceTimer?.invalidate(); graceTimer = nil
        lostKey = nil
        windowPicker?.close(); windowPicker = nil
        capture.stop()
        SCContentSharingPicker.shared.isActive = false
        capture.blanked = false
        output?.orderOut(nil)
        output = nil
        capture.window = nil
        if let t = target, !showDesktop, modes[t.id] == .windowOrApp { modes[t.id] = nil }
        target = nil
        updateFence()
    }

    /// Fence the presentation display off from the pointer (and stray windows) while it shows windows.
    private func updateFence() {
        guard let t = target, let screen = t.screen else {
            fence.stop(); rescueTimer?.invalidate(); rescueTimer = nil; return
        }
        if store.fencePointer { fence.start(fencing: screen.frame) } else { fence.stop() }

        rescueTimer?.invalidate(); rescueTimer = nil
        guard store.rescueWindows else { return }
        let fencedCG = CGDisplayBounds(t.id)
        let homeCG = CGDisplayBounds(primaryDisplayID(excluding: t.id))
        // Accessibility calls can block on a busy app, so they run off the main thread, one pass at a time.
        rescueTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.rescueBusy else { return }
            self.rescueBusy = true
            self.rescueQueue.async {
                WindowRescue.run(fenced: fencedCG, home: homeCG)
                DispatchQueue.main.async { self.rescueBusy = false }
            }
        }
    }

    // MARK: SCContentSharingPickerObserver (called off the main thread)

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async {
            guard self.target != nil else { return }
            self.capture.apply(filter)
            self.showNextChooserSoon()
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            log("picker cancelled")
            // Cancelling the first pick backs out of Window or App mode; the display stays extended.
            if self.capture.stream == nil { self.endWindowMode(showDesktop: true) }
            self.showNextChooserSoon()
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        log("picker failed: \(error)")
        DispatchQueue.main.async {
            let a = NSAlert(); a.messageText = "Couldn’t open the window picker"; a.informativeText = error.localizedDescription
            a.runModal()
            self.endWindowMode(showDesktop: true)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = ExternalDisplay.online().filter { !$0.isVirtual }
        if displays.isEmpty {
            menu.addItem(disabled("No external display connected"))
            menu.addItem(.separator())
        }
        for d in displays {
            let rule = store.rule(for: d.key)
            let state: String
            if target == d { state = capture.stream == nil ? "Choosing windows…" : (capture.blanked ? "Blanked" : "Showing selected windows") }
            else if rule == .ignore { state = "Ignored" }
            else if d.isMirrored { state = "Mirroring entire screen" }
            else { state = "Extended display" }
            menu.addItem(disabled("\(d.name) — \(state)"))
            menu.addItem(item("Change What’s Shown…", #selector(openChooser(_:)), d.id))
            if target == d {
                menu.addItem(item(capture.stream == nil ? "Choose Windows…" : "Add or Remove Windows…", #selector(changeWindows), nil))
                let blank = item("Blank Screen", #selector(toggleBlank), nil); blank.state = capture.blanked ? .on : .off
                menu.addItem(blank)
                menu.addItem(item("Stop Showing Windows", #selector(stopWindows), nil))
            }
            let whenConnected = NSMenuItem(title: "When Connected", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for r in Rule.allCases {
                let i = item(r.title, #selector(setRule(_:)), d.id)
                i.representedObject = [NSNumber(value: d.id), r.rawValue] as NSArray
                i.state = r == rule ? .on : .off
                sub.addItem(i)
            }
            whenConnected.submenu = sub
            menu.addItem(whenConnected)
            menu.addItem(.separator())
        }
        // AirPlay
        if let name = airPlayReceiver {
            menu.addItem(item("Stop AirPlay to “\(name)”", #selector(stopAirPlay), nil))
        } else if let pending = pendingAirPlay {
            menu.addItem(disabled("Connecting to “\(pending.name)”…"))
        } else {
            let airPlayItem = NSMenuItem(title: "AirPlay to", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in airPlay.receivers {
                let i = NSMenuItem(title: name, action: #selector(airPlayMenuPick(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = name; i.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
                sub.addItem(i)
            }
            if airPlay.receivers.isEmpty { sub.addItem(disabled("Looking for AirPlay TVs…")) }
            sub.addItem(.separator())
            sub.addItem(item("Choose…", #selector(showAirPlayPicker), nil))
            airPlayItem.submenu = sub
            menu.addItem(airPlayItem)
        }
        menu.addItem(.separator())
        menu.addItem(disabled("WirePlay \(appVersion)"))
        let s = item("Settings…", #selector(showSettings), nil); s.keyEquivalent = ","
        menu.addItem(s)
        menu.addItem(NSMenuItem(title: "Quit WirePlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    private func item(_ title: String, _ action: Selector, _ displayID: CGDirectDisplayID?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let displayID { i.representedObject = NSNumber(value: displayID) }
        return i
    }

    @objc private func openChooser(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber { showChooser(for: ExternalDisplay(id: n.uint32Value)) }
    }

    @objc private func setRule(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? NSArray, let n = pair[0] as? NSNumber,
              let raw = pair[1] as? String, let rule = Rule(rawValue: raw) else { return }
        let d = ExternalDisplay(id: n.uint32Value)
        store.setRule(rule, for: d.key, name: d.name)
        if rule == .ignore, target == d { endWindowMode(showDesktop: true) }
    }

    @objc private func changeWindows() { presentPicker() }
    @objc private func stopWindows() {
        if airPlayReceiver != nil { stopAirPlay(); return }
        if let t = target { endWindowMode(showDesktop: true); modes[t.id] = .extendedDisplay }
    }

    @objc private func toggleBlank() {
        capture.blanked.toggle()
        if capture.blanked { output?.videoLayer.contents = nil }
    }
}

if CommandLine.arguments.contains("--dump-airplay") { AirPlayProbe.run(); exit(0) }

// `WirePlay --preview out.png` renders the chooser to an image (for checking the UI without a display).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview" { MainActor.assumeIsolated {
    let view = ChooserView(model: ChooserModel(displayName: "Conference Room TV", initial: .windowOrApp))
        .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: view); renderer.scale = 2
    if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
} }

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-icon" {
    Glyph.writeIconset(to: CommandLine.arguments[2]); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
