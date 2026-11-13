import Core
import Foundation
import Persistence

/// The diary's supplements section: the doses due on the day and the extra doses, and logging them.
extension DiaryModel {
    func observeSupplements() async {
        guard let repo = environment.supplements else { return }
        let day = day
        await Self.resubscribing {
            repo.observeDay(day)
        } onValue: { value in
            supplementDay = value
        } onError: { error in
            errorMessage = error.localizedDescription
        }
    }

    /// When a dose logged now on the shown day counts as taken: now on today; on another day the dose's time (or
    /// noon for an extra dose), on that day.
    func takenTime(for minute: Int?) -> Date {
        let now = environment.clock.now()
        guard !isToday else { return now }
        return SupplementSlot(day: day, minute: minute ?? 12 * 60).date(calendar: .autoupdatingCurrent)
    }

    /// Whether a scheduled dose that is still open is late: its time has passed.
    func isOverdue(_ row: SupplementDay.Row) -> Bool {
        guard row.dose == nil, let minute = row.minute else { return false }
        return SupplementSlot(day: day, minute: minute).date(calendar: .autoupdatingCurrent) < environment.clock.now()
    }

    /// The circle's tap: an open or skipped dose is taken, a taken one is open again (an extra dose is deleted).
    func toggleTaken(_ row: SupplementDay.Row) {
        if row.isTaken {
            undoLog(row)
        } else {
            markTaken(row, at: takenTime(for: row.minute))
        }
    }

    func markTaken(_ row: SupplementDay.Row, at date: Date) {
        performSupplements { repo in
            if let key = row.key {
                try repo.markTaken([key], at: date)
            } else if let dose = row.dose {
                try repo.setTakenAt(doseID: dose.id, date)
            }
        }
    }

    func markSkipped(_ row: SupplementDay.Row) {
        guard let key = row.key else { return }
        performSupplements { try $0.markSkipped([key]) }
    }

    /// Clears what was logged: a scheduled dose is open again, an extra dose is deleted.
    func undoLog(_ row: SupplementDay.Row) {
        performSupplements { repo in
            if let key = row.key {
                try repo.clear(key)
            } else if let dose = row.dose {
                try repo.deleteDose(id: dose.id)
            }
        }
    }

    /// Every scheduled dose of the day that is still open, taken now (or at its time on another day).
    func markAllTaken() {
        let open = supplementDay?.rows.filter { $0.dose == nil && $0.key != nil } ?? []
        guard !open.isEmpty else { return }
        performSupplements { repo in
            for row in open {
                guard let key = row.key else { continue }
                try repo.markTaken([key], at: takenTime(for: row.minute))
            }
        }
    }

    var hasOpenSupplementDoses: Bool {
        supplementDay?.rows.contains { $0.dose == nil && $0.key != nil } ?? false
    }

    func logExtraDose(_ supplement: Supplement, at date: Date? = nil) {
        performSupplements { try $0.logExtra(supplementID: supplement.id, day: day, at: date ?? takenTime(for: nil)) }
    }

    private func performSupplements(_ action: (SupplementRepository) throws -> Void) {
        guard let repo = environment.supplements else { return }
        do {
            try action(repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
