import Core
import Foundation
import GRDB
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

struct LocalBackupsTests {
    private func makeBackups(_ f: Fixture) -> (LocalBackups, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        return (LocalBackups(directory: dir, portability: f.portability, clock: f.clock.appClock), dir)
    }

    @Test func `weekly backups, newest seven kept`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try backups.list().isEmpty)

        let first = try #require(try backups.backupIfDue())
        #expect(first.createdAt == Date(timeIntervalSince1970: f.clock.now.timeIntervalSince1970.rounded(.down)))
        #expect(first.sizeBytes > 100)
        f.clock.advance(6 * 86400)
        #expect(try backups.backupIfDue() == nil) // not a week yet
        f.clock.advance(86400)
        #expect(try backups.backupIfDue() != nil)
        #expect(try backups.list().count == 2)

        for _ in 0 ..< 8 {
            f.clock.advance(7 * 86400)
            try backups.backupIfDue()
        }
        let kept = try backups.list()
        #expect(kept.count == LocalBackups.keep)
        #expect(kept.map(\.createdAt) == kept.map(\.createdAt).sorted(by: >))
        #expect(!kept.contains { $0.url == first.url }) // the oldest are gone
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 7)
    }

    @Test func `manual backup, other files ignored, delete`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manual = try backups.backupNow()
        f.clock.advance(5)
        let second = try backups.backupNow() // "back up now" ignores the weekly rhythm
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("vitalion-backup-garbage.json"))
        #expect(try backups.list().map(\.url.lastPathComponent) == [second.url.lastPathComponent, manual.url.lastPathComponent])
        try backups.delete(manual)
        #expect(try backups.list().count == 1)
        #expect(LocalBackups.date(fromFileName: "vitalion-backup-20261109T140312Z.json") == Timestamp.date("2026-11-09T14:03:12Z"))
        #expect(try LocalBackups
            .fileName(for: #require(Timestamp.date("2026-11-09T14:03:12.900Z"))) == "vitalion-backup-20261109T140312Z.json")
        // Backups from before the rename (Nutrilog) are still listed and restorable.
        #expect(LocalBackups.date(fromFileName: "nutrilog-backup-20261109T140312Z.json") == Timestamp.date("2026-11-09T14:03:12Z"))
        let legacy = dir.appendingPathComponent("nutrilog-backup-20200101T000000Z.json")
        try FileManager.default.copyItem(at: second.url, to: legacy)
        let listed = try backups.list()
        #expect(listed.map(\.url.lastPathComponent) == [second.url.lastPathComponent, legacy.lastPathComponent])
        _ = try backups.restore(#require(listed.last))
    }

    @Test func `restore brings the data back`() throws {
        let f = try Fixture()
        let (backups, dir) = makeBackups(f)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rice = try f.makeFood("Rice", kcal: 130)
        try f.diary.log(food: rice, quantity: .base(200), slotID: "lunch", day: day("2026-11-09"))
        let backup = try backups.backupNow()

        f.clock.advance(3600)
        try f.foods.softDelete(id: rice.id)
        try f.diary.log(food: rice, quantity: .base(900), slotID: "dinner", day: day("2026-11-09"))
        try backups.restore(backup)
        #expect(try f.diary.totals(for: day("2026-11-09")).kcal == 260)
        #expect(try f.foods.food(id: rice.id)?.deletedAt == nil)
    }
}
