import Foundation

/// Decides which camera detections reach the caller. Pure, so it can be tested without a camera.
///
/// - Drops repeat detections of the same code within `interval` (default 2 s) of its last accepted detection, so a
///   code held in front of the camera fires the callback once. A different code is accepted immediately.
/// - After a pause (a result sheet covered the camera, then "Log" or "Scan another" brought it back), the code
///   handled last is still in front of the camera and VisionKit reports it again. ``resume(at:)`` suppresses that
///   one code for `resumeSuppression` (default 3 s): a different code is still accepted immediately, and the same
///   code is accepted again once the period has passed or after it left the view (``codeLeftView(_:)``).
public struct ScanDebouncer: Sendable {
    public let interval: TimeInterval
    public let resumeSuppression: TimeInterval
    private var lastAccepted: [String: Date] = [:]
    /// The code handed to the caller last (camera or manual entry).
    private var lastHandled: String?
    private var suppression: Suppression?

    private struct Suppression: Sendable {
        let code: String
        let until: Date
        /// The code was reported (and dropped) since the resume. Only then does its removal mean that it left the
        /// view: a removal reported for a detection from before the pause says nothing about now.
        var wasSeen = false
    }

    public init(interval: TimeInterval = 2, resumeSuppression: TimeInterval = 3) {
        self.interval = interval
        self.resumeSuppression = resumeSuppression
    }

    /// Returns `true` when `code` should be reported, and records it as accepted at `date`.
    public mutating func accept(_ code: String, at date: Date = .now) -> Bool {
        if let active = suppression, date >= active.until {
            suppression = nil
        }
        if suppression?.code == code {
            suppression?.wasSeen = true
            return false
        }
        lastAccepted = lastAccepted.filter { date.timeIntervalSince($0.value) < interval }
        if lastAccepted[code] != nil {
            return false
        }
        lastAccepted[code] = date
        lastHandled = code
        return true
    }

    /// Records a code handed to the caller without going through ``accept(_:at:)``, e.g. one typed by hand, so the
    /// next ``resume(at:)`` suppresses it too. Doesn't affect the repeat interval.
    public mutating func noteHandled(_ code: String) {
        lastHandled = code
    }

    /// Scanning stopped: suppress the code handled last until the matching ``resume(at:)`` starts its countdown, so
    /// the suppression holds even if a detection were reported before the resume is recorded.
    public mutating func pause() {
        suppression = lastHandled.map { Suppression(code: $0, until: .distantFuture) }
    }

    /// Scanning resumed after a pause: suppress the code handled last until `date + resumeSuppression`, or until it
    /// left the view. A no-op when nothing was handled yet (the first start).
    public mutating func resume(at date: Date = .now) {
        suppression = lastHandled.map { code in
            Suppression(
                code: code,
                until: date.addingTimeInterval(resumeSuppression),
                wasSeen: suppression?.code == code && suppression?.wasSeen == true,
            )
        }
    }

    /// The camera no longer sees `code`. Ends the resume suppression of that code if it was seen since the resume,
    /// so bringing the same product back into view is accepted. The repeat interval still applies.
    public mutating func codeLeftView(_ code: String) {
        if let active = suppression, active.code == code, active.wasSeen {
            suppression = nil
        }
    }

    /// Forgets all codes, e.g. when the scanner is reopened.
    public mutating func reset() {
        lastAccepted.removeAll()
        lastHandled = nil
        suppression = nil
    }
}
