import Core
import Foundation
import Persistence
import Synchronization

/// A clock that tests move forward by hand.
final class ManualClock: Sendable {
    private let date: Mutex<Date>

    /// Starts at local noon of `day`, so whole-day steps never land on a midnight boundary.
    init(day: String = "2026-11-09") {
        let midnight = LocalDay(day)?.startDate() ?? Date(timeIntervalSinceReferenceDate: 0)
        date = Mutex(midnight.addingTimeInterval(12 * 3600))
    }

    var appClock: AppClock {
        AppClock { [self] in date.withLock { $0 } }
    }

    func advance(hours: Double) {
        date.withLock { $0 = $0.addingTimeInterval(hours * 3600) }
    }
}

/// Waits (up to `timeout`) until `condition` holds — for values delivered by database observations.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
