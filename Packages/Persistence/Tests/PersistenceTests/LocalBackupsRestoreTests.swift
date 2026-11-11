import Core
import Foundation
import Testing
@testable import Persistence

struct LocalBackupsRestoreTests {
    private func makeBackups(_ f: Fixture) -> (LocalBackups, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        return (LocalBackups(directory: dir, portability: f.portability, clock: f.clock.appClock), dir)
    }

    @Test func `restoring the oldest of seven keeps a copy of the current data and restores the chosen backup`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rice = try f.makeFood("Rice", kcal: 130)
        let d = day("2026-11-09")
        // The oldest backup holds 100 g of rice (130 kcal); each later one adds 100 g more.
        try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: d)
        for _ in 0 ..< LocalBackups.keep {
            try backups.backupNow()
            f.clock.advance(7 * 86400)
            try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: d)
        }
        let listed = try backups.list()
        #expect(listed.count == LocalBackups.keep)
        let oldest = try #require(listed.last)
        let currentKcal = try f.diary.totals(for: d).kcal
        #expect(currentKcal == 130 * Double(LocalBackups.keep + 1))

        let result = try backups.restoreKeepingCurrent(oldest)
        #expect(try f.diary.totals(for: d).kcal == 130)
        // The safety backup is the newest, and the restored one was not pruned to make room for it.
        let after = try backups.list()
        #expect(after.first?.url.lastPathComponent == result.safetyBackup.url.lastPathComponent)
        #expect(after.contains { $0.url.lastPathComponent == oldest.url.lastPathComponent })
        #expect(after.count == LocalBackups.keep + 1)

        // Undo: the safety backup brings back the data from before the restore.
        f.clock.advance(60)
        try backups.restoreKeepingCurrent(result.safetyBackup)
        #expect(try f.diary.totals(for: d).kcal == currentKcal)
        // The next backup prunes back to the newest seven.
        f.clock.advance(60)
        try backups.backupNow()
        #expect(try backups.list().count == LocalBackups.keep)
    }

    @Test func `nothing is replaced when the chosen backup can't be read`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rice = try f.makeFood("Rice", kcal: 130)
        let d = day("2026-11-09")
        try f.diary.log(food: rice, quantity: .base(100), slotID: "lunch", day: d)
        let backup = try backups.backupNow()
        try backups.delete(backup)
        f.clock.advance(60)
        #expect(throws: (any Error).self) { try backups.restoreKeepingCurrent(backup) }
        #expect(try f.diary.totals(for: d).kcal == 130)
        #expect(try backups.list().isEmpty) // no safety backup either: nothing changed
    }
}
