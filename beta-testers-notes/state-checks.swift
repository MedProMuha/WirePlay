// Historical characterization of extracted logic at 0b45184.
// These assertions demonstrate baseline defects; they do not exercise or validate the app.
import Foundation
final class Panel { var closed = false; func close() { closed = true } }
final class Controller {
    var airPlayPicker: Panel? = Panel()
    var airPlayPickerModel: String? = "active"
    var pendingAirPlay: (name: String, until: Date)?
    var failed = false
    func closeAirPlayPicker() {
        airPlayPicker?.close(); airPlayPicker = nil; airPlayPickerModel = nil
    }

    func timeout(_ name: String) -> () -> Void {
        return { [weak self] in
            guard let self, self.pendingAirPlay?.name == name else { return }
            self.airPlayFailed(name, "“\(name)” didn’t connect. Is it on, and on the same network?")
        }
    }
    func airPlayFailed(_ name: String, _ message: String) { failed = true; pendingAirPlay = nil }
}
struct ExternalDisplay {
    let id: Int
    let hardwareName: String
    var airPlayReceiver: String? { hardwareName.hasSuffix(" (AirPlay)") ? String(hardwareName.dropLast(" (AirPlay)".count)) : nil }
    var isVirtual: Bool { let n = hardwareName.lowercased(); return n.contains("airplay") || n.contains("sidecar") }
    static func online() -> [ExternalDisplay] { [ExternalDisplay(id: 1, hardwareName: "TV (AirPlay)")] }
}
func matched(_ displays: [ExternalDisplay], known: Set<Int>, pendingAirPlay: (name: String, until: Date)?) -> [Int] {
    var hits: [Int] = []
    for d in displays where !known.contains(d.id) {
        if let pending = pendingAirPlay, Date() < pending.until,
           d.airPlayReceiver == pending.name || (d.airPlayReceiver == nil && d.isVirtual) { hits.append(d.id) }
    }
    return hits
}
let controller = Controller()
controller.pendingAirPlay = ("Room TV", Date().addingTimeInterval(25))
let panel = controller.airPlayPicker!
controller.closeAirPlayPicker()
assert(panel.closed && controller.pendingAirPlay != nil)
print("CONFIRMED: Cancel closes picker but retains pending AirPlay request")
let oldTimeout = controller.timeout("Room TV")
controller.pendingAirPlay = ("Room TV", Date().addingTimeInterval(25))
oldTimeout()
assert(controller.failed && controller.pendingAirPlay == nil)
print("CONFIRMED: old timeout clears a newer same-name retry")
let pending = (name: "Room TV", until: Date().addingTimeInterval(25))
assert(matched([ExternalDisplay(id: 2, hardwareName: "iPad (Sidecar)")], known: [], pendingAirPlay: pending) == [2])
print("CONFIRMED: unrelated new Sidecar display is accepted as pending Room TV")
assert(matched([ExternalDisplay(id: 2, hardwareName: "Room TV (AirPlay)")], known: [2], pendingAirPlay: pending).isEmpty)
print("CONFIRMED: already-known matching AirPlay display cannot complete request")
let displays = ExternalDisplay.online().filter { !$0.isVirtual }
assert(displays.isEmpty)
print("CONFIRMED: active AirPlay display excluded from menu's presentation-controls loop")
