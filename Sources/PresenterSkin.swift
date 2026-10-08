import Cocoa
import Combine
import SwiftUI

// Native version of the approved presenter skin. All content comes from the session models.
private enum PresenterSkin {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let surface = adaptive(0xFBFBFC, 0x24262E)
    static let panel = adaptive(0xF2F3F6, 0x2B2E38)
    static let card = adaptive(0xFFFFFF, 0x30333E)
    static let line = adaptive(0xDCDFe6, 0x414550)
    static let accent = adaptive(0x5749BD, 0xB3A6FF)
    static let accentFill = adaptive(0x5749BD, 0x7966DF)
    static let accentSoft = adaptive(0xEEEBFC, 0x393251)
    static let muted = adaptive(0x656977, 0xB2B3C0)
    static let green = adaptive(0x206B55, 0x8CD2AE)
    static let amber = adaptive(0x866314, 0xF1CF85)
    static let red = adaptive(0xB33F41, 0xFFABA9)
}

private struct SkinHeader: View {
    let detail: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "airplay.video").font(.system(size: 20, weight: .medium))
                .foregroundStyle(PresenterSkin.accent).accessibilityHidden(true)
            Text("WirePlay").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(PresenterSkin.muted)
        }
        .padding(.leading, 84).padding(.trailing, 24).frame(height: 48)
        .background(PresenterSkin.panel)
        .overlay(alignment: .bottom) { PresenterSkin.line.frame(height: 1) }
    }
}

private struct SkinError: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12)).foregroundStyle(PresenterSkin.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(PresenterSkin.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

final class PresenterModel: ObservableObject {
    @Published var destination = ""
    @Published var connection = ""
    @Published var status = ""
    @Published var windows: [String] = []
    @Published var sharesApps = false
    @Published var preview: NSImage?
    @Published var isBlank = false
    @Published var isFrozen = false
    @Published var busy = false
    @Published var error: String?
    @Published var stopTitle = "Stop AirPlay"
    var onChange: () -> Void = {}
    var onFreeze: () -> Void = {}
    var onBlank: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetry: () -> Void = {}
}

struct PresenterView: View {
    @ObservedObject var model: PresenterModel

    private var stateColor: Color {
        model.error != nil ? PresenterSkin.red : model.isBlank || model.isFrozen ? PresenterSkin.amber : PresenterSkin.green
    }

    var body: some View {
        VStack(spacing: 0) {
            SkinHeader(detail: "PRESENTER")
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("WINDOW SHARING").font(.system(size: 10, weight: .semibold))
                            .tracking(0.8).foregroundStyle(PresenterSkin.muted)
                        Text(model.destination).font(.system(size: 23, weight: .semibold))
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if model.busy { ProgressView().controlSize(.mini) }
                        else { Circle().fill(stateColor).frame(width: 6, height: 6).accessibilityHidden(true) }
                        Text(model.connection).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(stateColor).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(stateColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                if let error = model.error { SkinError(text: error) }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Outgoing preview").fontWeight(.medium)
                            Spacer()
                            Text(model.status).foregroundStyle(stateColor).lineLimit(2)
                        }.font(.system(size: 11)).foregroundStyle(PresenterSkin.muted)
                        ZStack {
                            Color.black
                            if model.isBlank {
                                VStack(spacing: 9) {
                                    Image(systemName: "rectangle.slash").font(.system(size: 28))
                                    Text("Output is blank").font(.system(size: 12, weight: .medium))
                                    Text("Resume when you are ready.").font(.system(size: 11))
                                }.foregroundStyle(Color.white.opacity(0.75))
                            } else if let preview = model.preview {
                                Image(nsImage: preview).resizable().scaledToFit()
                                    .accessibilityLabel("Preview of the selected windows being sent to the display")
                            } else {
                                VStack(spacing: 9) {
                                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 28))
                                    Text("Waiting for a captured frame").font(.system(size: 12))
                                }.foregroundStyle(Color.white.opacity(0.7))
                            }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(5).background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .bottomLeading) {
                            if model.isFrozen && !model.isBlank {
                                Text("Frozen · last frame stays visible")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.black).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color(red: 0.98, green: 0.84, blue: 0.49), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(13)
                            }
                        }
                        Text("Preview of WirePlay’s output. Check the TV to confirm it is visible.")
                            .font(.system(size: 10)).foregroundStyle(PresenterSkin.muted)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(model.sharesApps ? "Shared apps / windows" : "Selected windows") \(model.windows.count)")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(PresenterSkin.muted)
                            Spacer(minLength: 6)
                            Button("Change…", action: model.onChange)
                                .buttonStyle(.link).font(.system(size: 11)).tint(PresenterSkin.accent)
                                .disabled(model.busy || model.error != nil)
                                .accessibilityLabel("Change shared windows")
                        }.frame(minHeight: 22)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(model.windows.enumerated()), id: \.offset) { _, title in
                                    HStack(alignment: .top, spacing: 9) {
                                        Image(systemName: "macwindow").font(.system(size: 16))
                                            .foregroundStyle(PresenterSkin.accent)
                                            .padding(7).background(PresenterSkin.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                                            .accessibilityHidden(true)
                                        Text(title).font(.system(size: 12, weight: .medium))
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.vertical, 11)
                                    PresenterSkin.line.frame(height: 1)
                                }
                                if model.windows.isEmpty {
                                    Text("No windows selected").font(.system(size: 12)).foregroundStyle(PresenterSkin.muted)
                                        .padding(.vertical, 16)
                                }
                            }
                        }.frame(maxHeight: 180)
                        HStack {
                            Text("Audio").foregroundStyle(PresenterSkin.muted)
                            Spacer()
                            Text("Not included")
                        }.font(.system(size: 11)).padding(.top, 14)
                        Text(model.isBlank ? "Change windows while the output stays blank."
                             : model.isFrozen ? "Selection changes appear when you resume."
                             : model.sharesApps ? "All windows from selected apps are included." : "Only the selected windows are included.")
                            .font(.system(size: 11)).foregroundStyle(PresenterSkin.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 9)
                    }.frame(width: 235)
                }
            }.padding(26)
            PresenterSkin.line.frame(height: 1)
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.isBlank ? "Blank output" : model.isFrozen ? "Last frame is visible" : "Window sharing")
                        .font(.system(size: 12, weight: .medium))
                    Text("⌘B blank · ⌘F freeze").font(.system(size: 10)).foregroundStyle(PresenterSkin.muted)
                }
                Spacer(minLength: 8)
                if model.error != nil {
                    Button("Try again", action: model.onRetry).buttonStyle(.borderedProminent)
                        .tint(PresenterSkin.accentFill).disabled(model.busy)
                } else {
                    Button(action: model.onFreeze) {
                        Label(model.isFrozen ? "Resume live" : "Freeze frame", systemImage: model.isFrozen ? "play" : "pause")
                    }.keyboardShortcut("f", modifiers: .command)
                        .disabled(model.busy || model.isBlank || model.preview == nil)
                        .accessibilityValue(model.isFrozen ? "Frozen" : "Live")
                    Button(action: model.onBlank) {
                        Label(model.isBlank ? "Resume live" : "Blank screen", systemImage: model.isBlank ? "play" : "rectangle.slash")
                    }.buttonStyle(.borderedProminent).tint(PresenterSkin.accentFill)
                        .keyboardShortcut("b", modifiers: .command).disabled(model.busy)
                        .accessibilityValue(model.isBlank ? "Blank" : "Showing windows")
                }
                Button(action: model.onStop) { Label(model.stopTitle, systemImage: "stop") }
                    .tint(PresenterSkin.red).foregroundStyle(PresenterSkin.red).disabled(model.busy)
                    .padding(.leading, 5)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 24).padding(.vertical, 16).background(PresenterSkin.panel)
        }
        .frame(width: 800).background(PresenterSkin.surface).tint(PresenterSkin.accent)
    }
}

struct SkinnedWindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    @State private var query = ""
    @FocusState private var focusedWindow: CGWindowID?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)
    private var matches: [WindowPickerModel.Item] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? model.items : model.items.filter { ($0.app + " " + $0.title).localizedCaseInsensitiveContains(term) }
    }
    private var selectedNames: String {
        model.items.filter { model.selected.contains($0.id) }
            .map { $0.title.isEmpty ? $0.app : "\($0.app): \($0.title)" }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            SkinHeader(detail: "CHOOSE WINDOWS")
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(PresenterSkin.muted)
                    Text("Choose your windows").font(.system(size: 24, weight: .semibold))
                    Text(model.isEditing ? "Your current output stays unchanged until you apply this selection."
                         : "Select only what you want to share. Your other windows stay out of the presentation.")
                        .font(.system(size: 12)).foregroundStyle(PresenterSkin.muted)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(PresenterSkin.muted).accessibilityHidden(true)
                        TextField("Search app or window title", text: $query).textFieldStyle(.plain)
                            .accessibilityLabel("Search windows by app or title")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(PresenterSkin.muted).accessibilityLabel("Clear search")
                        }
                    }.padding(10).background(PresenterSkin.card, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(PresenterSkin.line))
                    Text("\(model.chosen.count) selected").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PresenterSkin.accent).padding(8)
                        .background(PresenterSkin.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                    Button(action: model.onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered).disabled(model.loading).help("Refresh windows")
                        .accessibilityLabel("Refresh windows")
                }
                Group {
                    if model.loading {
                        ProgressView("Finding windows…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let failure = model.failure {
                        VStack(spacing: 15) {
                            SkinError(text: "WirePlay couldn’t list your windows. \(failure)")
                            Text("Allow Screen & System Audio Recording in System Settings, then try again. You can also use the macOS picker below.")
                                .font(.system(size: 12)).foregroundStyle(PresenterSkin.muted).multilineTextAlignment(.center)
                            Button("Open Screen Recording Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.buttonStyle(.bordered)
                            Button("Try again", action: model.onRefresh).buttonStyle(.borderedProminent).tint(PresenterSkin.accentFill)
                        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if matches.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "macwindow").font(.system(size: 30)).foregroundStyle(PresenterSkin.muted)
                            Text(query.isEmpty ? "No windows to show yet" : "No matching windows").font(.headline)
                            Text(query.isEmpty ? "Open a window on your Mac, then refresh the list. Minimized windows may not appear." : "Try another app name or window title.")
                                .font(.system(size: 12)).foregroundStyle(PresenterSkin.muted).multilineTextAlignment(.center)
                            Button(query.isEmpty ? "Refresh windows" : "Clear search") {
                                if query.isEmpty { model.onRefresh() } else { query = "" }
                            }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 19) {
                                ForEach(matches) { item in
                                    Button { model.toggle(item.id) } label: {
                                        windowCard(item, selected: model.selected.contains(item.id))
                                    }
                                    .buttonStyle(.plain).focused($focusedWindow, equals: item.id)
                                    .accessibilityLabel("\(item.app): \(item.title.isEmpty ? "Untitled window" : item.title)")
                                    .accessibilityValue(model.selected.contains(item.id) ? "Selected" : "Not selected")
                                    .accessibilityHint("Toggle inclusion in your presentation")
                                }
                            }.padding(3)
                        }
                    }
                }.frame(height: 365)
                Label(selectedNames.isEmpty ? "Nothing selected." : "Selected: \(selectedNames)", systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(PresenterSkin.accent)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .help(selectedNames)
            }.padding(26)
            PresenterSkin.line.frame(height: 1)
            HStack(spacing: 10) {
                Button("Use macOS picker", action: model.onUseSystemPicker).buttonStyle(.link).tint(PresenterSkin.accent)
                Spacer()
                Button(model.isEditing ? "Cancel changes" : "Cancel") { model.onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.isEditing ? "Apply selection" : model.showTitle) { model.onDone(model.chosen) }
                    .buttonStyle(.borderedProminent).tint(PresenterSkin.accentFill).keyboardShortcut(.defaultAction)
                    .disabled(model.chosen.isEmpty || model.loading || model.failure != nil)
            }.buttonStyle(.bordered).controlSize(.large)
                .padding(.horizontal, 24).padding(.vertical, 16).background(PresenterSkin.panel)
        }.frame(width: 820).background(PresenterSkin.surface).tint(PresenterSkin.accent)
    }

    private func windowCard(_ item: WindowPickerModel.Item, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(selected ? PresenterSkin.accentSoft : PresenterSkin.panel)
                if let thumb = model.thumbs[item.id] {
                    Image(nsImage: thumb).resizable().scaledToFit().padding(7).accessibilityHidden(true)
                } else if model.completedThumbnailIDs.contains(item.id) {
                    VStack(spacing: 7) {
                        Image(systemName: "macwindow").font(.system(size: 25))
                        Text("Preview unavailable").font(.system(size: 10))
                    }.foregroundStyle(PresenterSkin.muted)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading window preview")
                }
            }
            .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected || focusedWindow == item.id ? PresenterSkin.accent : PresenterSkin.line,
                                                             lineWidth: selected || focusedWindow == item.id ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21)).foregroundStyle(selected ? PresenterSkin.accent : PresenterSkin.muted)
                    .background(PresenterSkin.surface, in: Circle()).padding(10).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 27, height: 27).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.app).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(item.title.isEmpty ? "Untitled window" : item.title).font(.system(size: 12))
                        .foregroundStyle(PresenterSkin.muted).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 43, alignment: .top)
        }.contentShape(Rectangle()).help(item.title.isEmpty ? item.app : "\(item.app): \(item.title)")
    }
}

struct SkinnedAirPlayPickerView: View {
    @ObservedObject var model: AirPlayPickerModel
    @ObservedObject var browser: AirPlayBrowser
    @State private var selected: String?
    @FocusState private var focusedReceiver: String?
    init(model: AirPlayPickerModel) { self.model = model; browser = model.browser }

    var body: some View {
        VStack(spacing: 0) {
            SkinHeader(detail: "AIRPLAY")
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Where are you presenting?").font(.system(size: 24, weight: .semibold))
                    Text("Choose an AirPlay receiver. You will choose windows next.")
                        .font(.system(size: 12)).foregroundStyle(PresenterSkin.muted)
                }
                if let error = model.error ?? browser.failure { SkinError(text: error) }
                Group {
                    if browser.receivers.isEmpty {
                        VStack(spacing: 13) {
                            if browser.searching { ProgressView("Looking for AirPlay TVs…") }
                            else {
                                Image(systemName: "tv").font(.system(size: 30)).foregroundStyle(PresenterSkin.muted)
                                Text("No TVs found").font(.headline)
                                Text("Enable AirPlay on the TV and connect your Mac to the same network.")
                                    .font(.system(size: 12)).foregroundStyle(PresenterSkin.muted).multilineTextAlignment(.center)
                                Button("Try discovery again") { browser.retry() }
                                    .buttonStyle(.bordered).disabled(model.connecting != nil)
                            }
                        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(browser.receivers, id: \.self) { name in
                                    Button { selected = name } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "tv").font(.system(size: 27)).foregroundStyle(PresenterSkin.accent)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(name).font(.system(size: 14, weight: .semibold))
                                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                                Text(model.connecting == name ? "Connecting…" : "AirPlay receiver")
                                                    .font(.system(size: 11)).foregroundStyle(PresenterSkin.muted)
                                            }
                                            if model.connecting == name { ProgressView().controlSize(.small) }
                                            else {
                                                Image(systemName: selected == name ? "largecircle.fill.circle" : "circle")
                                                    .foregroundStyle(selected == name ? PresenterSkin.accent : PresenterSkin.muted)
                                                    .accessibilityHidden(true)
                                            }
                                        }.padding(18).contentShape(Rectangle())
                                            .background(selected == name ? PresenterSkin.accentSoft : PresenterSkin.card)
                                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focusedReceiver == name ? PresenterSkin.accent : .clear, lineWidth: 2))
                                    }.buttonStyle(.plain).disabled(model.connecting != nil)
                                        .focused($focusedReceiver, equals: name)
                                        .accessibilityLabel(name).accessibilityValue(selected == name ? "Selected" : "Not selected")
                                }
                            }.padding(2).background(PresenterSkin.line, in: RoundedRectangle(cornerRadius: 9))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(height: 235)
                Text("Check that the TV is free. macOS may briefly show your desktop while connecting; close private windows first.")
                    .font(.system(size: 11)).foregroundStyle(PresenterSkin.muted)
                if browser.receivers.isEmpty && !browser.searching {
                    Button("Open Local Network Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.link).font(.system(size: 11)).tint(PresenterSkin.accent)
                }
            }.padding(26)
            PresenterSkin.line.frame(height: 1)
            HStack(spacing: 10) {
                if let connecting = model.connecting {
                    Text("Connecting to \(connecting)").font(.system(size: 11)).foregroundStyle(PresenterSkin.muted).lineLimit(2)
                } else {
                    Button("Refresh") { browser.retry() }.disabled(browser.searching)
                }
                Spacer()
                Button("Cancel", action: model.onCancel).keyboardShortcut(.cancelAction)
                Button("Connect & choose windows") {
                    if let selected, browser.receivers.contains(selected), model.connecting == nil { model.onPick(selected) }
                }.buttonStyle(.borderedProminent).tint(PresenterSkin.accentFill).keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || !browser.receivers.contains(selected ?? "") || model.connecting != nil)
            }.buttonStyle(.bordered).controlSize(.large)
                .padding(.horizontal, 24).padding(.vertical, 16).background(PresenterSkin.panel)
        }.frame(width: 650).background(PresenterSkin.surface).tint(PresenterSkin.accent)
            .onChange(of: browser.receivers) { _, names in
                if let selected, !names.contains(selected) { self.selected = nil }
            }
    }
}

struct SkinnedChooserView: View {
    @ObservedObject var model: ChooserModel
    @FocusState private var focusedMode: ShowMode?
    var body: some View {
        VStack(spacing: 0) {
            SkinHeader(detail: "DISPLAY MODE")
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName).font(.system(size: 11)).foregroundStyle(PresenterSkin.muted)
                    Text("What would you like to show?").font(.system(size: 24, weight: .semibold))
                }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(ShowMode.allCases) { mode in
                        Button { model.mode = mode } label: {
                            ModeCard(mode: mode, selected: model.mode == mode)
                                .padding(8).background(model.mode == mode ? PresenterSkin.accentSoft : PresenterSkin.card,
                                                       in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focusedMode == mode ? PresenterSkin.accent : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).focused($focusedMode, equals: mode).disabled(!model.isAvailable(mode))
                            .opacity(model.isAvailable(mode) ? 1 : 0.45)
                            .accessibilityLabel(mode.title).accessibilityValue(model.mode == mode ? "Selected" : "Not selected")
                            .help(model.isAvailable(mode) ? mode.explanation(model.displayName) : "Open your Mac’s lid or connect another display to share individual windows.")
                    }
                }
                Text(model.mode.explanation(model.displayName)).font(.system(size: 12)).foregroundStyle(PresenterSkin.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.windowModeAvailable {
                    Text("Window sharing needs your Mac’s screen. Open its lid or connect another display.")
                        .font(.system(size: 11)).foregroundStyle(PresenterSkin.amber)
                }
            }.padding(26)
            PresenterSkin.line.frame(height: 1)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Remember this choice", isOn: $model.setAsDefault).toggleStyle(.checkbox).font(.system(size: 12))
                    Button("Ignore this display") { model.onDone(.ignore) }.buttonStyle(.link).font(.system(size: 11))
                }
                Spacer()
                Button("Cancel") { model.onDone(.cancel) }.keyboardShortcut(.cancelAction)
                Button(model.buttonTitle) { model.onDone(.show(model.mode, remember: model.setAsDefault)) }
                    .buttonStyle(.borderedProminent).tint(PresenterSkin.accentFill).keyboardShortcut(.defaultAction)
            }.buttonStyle(.bordered).controlSize(.large)
                .padding(.horizontal, 24).padding(.vertical, 16).background(PresenterSkin.panel)
        }.frame(width: 650).background(PresenterSkin.surface).tint(PresenterSkin.accent)
    }
}
