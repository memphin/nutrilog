import Foundation

/// Drops repeat detections of the same code within `interval` (default 2 s) of its last accepted detection,
/// so a code held in front of the camera fires the callback once. A different code is accepted immediately.
public struct ScanDebouncer: Sendable {
    public let interval: TimeInterval
    private var lastAccepted: [String: Date] = [:]

    public init(interval: TimeInterval = 2) {
        self.interval = interval
    }

    /// Returns `true` when `code` should be reported, and records it as accepted at `date`.
    public mutating func accept(_ code: String, at date: Date = .now) -> Bool {
        lastAccepted = lastAccepted.filter { date.timeIntervalSince($0.value) < interval }
        if lastAccepted[code] != nil {
            return false
        }
        lastAccepted[code] = date
        return true
    }

    /// Forgets all codes, e.g. when the scanner is reopened.
    public mutating func reset() {
        lastAccepted.removeAll()
    }
}
