// WirePlay's Control Center / menu bar button. It lives in its own extension (Control Center
// only loads controls from app extensions) and opens a wireplay:// link, which the WirePlay
// app handles by showing the "What do you want to show?" chooser.

import AppIntents
import AppKit
import SwiftUI
import WidgetKit

@main
struct WirePlayControls: WidgetBundle {
    var body: some Widget {
        ChooseControl()
    }
}

struct ChooseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.ben.WirePlay.Controls.choose") {
            ControlWidgetButton(action: ShowChooserIntent()) {
                Label("WirePlay", image: "wireplay.glyph") // custom symbol of the app icon (Assets.xcassets)
            }
        }
        .displayName("WirePlay")
        .description("Choose what to show on a wired (HDMI / USB-C) display.")
    }
}

/// Our own intent, so Xcode extracts App Intents metadata for it; a bare system OpenURLIntent
/// as the button action has none, and Control Center rejects the tap ("action intent without
/// linkAction").
struct ShowChooserIntent: AppIntent {
    static let title: LocalizedStringResource = "Change What’s Shown"
    static let description = IntentDescription("Opens WirePlay’s chooser for the connected display.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // Returning an OpenURLIntent from here is accepted but never carried out for a custom
        // scheme, so open the link directly. If that fails, nudge the running app instead.
        let opened = await MainActor.run { NSWorkspace.shared.open(URL(string: "wireplay://choose")!) }
        if !opened {
            DistributedNotificationCenter.default().postNotificationName(
                .init("dev.ben.WirePlay.choose"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        return .result()
    }
}
