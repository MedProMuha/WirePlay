import Foundation

/// One request owns all of its asynchronous work, including a late completion after Cancel.
final class AirPlayAttempt: @unchecked Sendable {
    let id = UUID()
    let name: String
    let deadline: Date
    private let lock = NSLock()
    private var cancelled = false
    private var requested = false
    private var connected = false

    init(name: String, timeout: TimeInterval = 25) {
        self.name = name
        deadline = Date().addingTimeInterval(timeout)
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var ownsConnection: Bool { lock.lock(); defer { lock.unlock() }; return requested }
    func markConnected() { lock.lock(); connected = true; lock.unlock() }
    func canRelease(receiverPresent: Bool, quiet: Bool, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !receiverPresent && quiet && (connected || now >= deadline)
    }
    var needsLateConnectionWatch: Bool { lock.lock(); defer { lock.unlock() }; return requested && !connected }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func beginRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        requested = true
        return true
    }
    static func receiver(in displayName: String) -> String? {
        let suffix = " (AirPlay)"
        guard displayName.hasSuffix(suffix) else { return nil }
        return String(displayName.dropLast(suffix.count))
    }
    func matches(receiver: String?) -> Bool { receiver == name }
}
