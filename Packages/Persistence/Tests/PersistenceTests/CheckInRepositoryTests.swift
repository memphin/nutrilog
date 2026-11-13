import Core
import Foundation
import GRDB
import Testing
@testable import Persistence

struct CheckInRepositoryTests {
    let monday = day("2026-11-09")

    @Test func `accepting writes an adaptive target and the estimate in one go`() throws {
        let f = try Fixture()
        try f.profiles.setTarget(Target(
            effectiveFrom: day("2026-10-01"), kcal: 2300, macros: MacroTargets(proteinG: 150, carbsG: 250, fatG: 78), origin: .formula,
        ))
        let estimate = try sampleEstimate()
        let target = Target(
            effectiveFrom: monday, kcal: 1950, macros: MacroTargets(proteinG: 150, carbsG: 190, fatG: 66), origin: .adaptive,
        )
        let record = try f.checkIns.record(
            estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted, appliedTarget: target,
            previousTargetKcal: 2300, goalChangeKgPerWeek: -0.5,
        )
        #expect(record.decision == .accepted)
        #expect(record.tdeeKcal == estimate.kcal)
        #expect(record.windowDays == 14)
        #expect(record.loggedDays == 14)
        #expect(record.confidence == estimate.confidence)
        #expect(record.appliedTargetKcal == 1950)
        #expect(record.previousTargetKcal == 2300)
        #expect(record.goalChangeKgPerWeek == -0.5)

        let current = try #require(try f.profiles.target(on: monday))
        #expect(current.kcal == 1950)
        #expect(current.origin == .adaptive)
        // Past days keep the target they had.
        #expect(try f.profiles.target(on: monday.previous)?.kcal == 2300)

        let stored = try #require(try f.checkIns.latest())
        #expect(stored == record)
        #expect(stored.estimate == estimate) // the days used survive the round trip
        #expect(stored.estimate?.days.count == 14)
    }

    @Test func `skipping keeps the target; edited stores the user's number`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let skipped = try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        #expect(skipped.appliedTargetKcal == nil)
        #expect(try f.profiles.target(on: monday) == nil)

        let next = monday.adding(days: 7)
        let custom = Target(effectiveFrom: next, kcal: 2100, macros: MacroTargets(proteinG: 150, carbsG: 220, fatG: 70), origin: .adaptive)
        let edited = try f.checkIns.record(
            estimate: sampleEstimate(end: next.previous, previous: skipped.tdeeKcal), checkInDay: next, proposedTargetKcal: 1950,
            decision: .edited, appliedTarget: custom,
        )
        #expect(edited.proposedTargetKcal == 1950)
        #expect(edited.appliedTargetKcal == 2100)
        #expect(try f.profiles.target(on: next)?.kcal == 2100)
        #expect(try f.checkIns.history().map(\.computedForDay) == [next, monday])
        #expect(try f.checkIns.history(limit: 1).count == 1)
        #expect(try f.checkIns.previousEstimateKcal(before: next) == skipped.tdeeKcal)
        #expect(try f.checkIns.previousEstimateKcal(before: monday) == nil)
        #expect(try f.checkIns.latest(onOrBefore: monday.adding(days: 3))?.computedForDay == monday)
    }

    @Test func `a second check-in on the same day replaces the first`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let first = try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        f.clock.advance(60)
        let target = Target(
            effectiveFrom: monday,
            kcal: 1950,
            macros: MacroTargets(proteinG: 150, carbsG: 190, fatG: 66),
            origin: .adaptive,
        )
        let second = try f.checkIns.record(
            estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted, appliedTarget: target,
        )
        #expect(second.id == first.id)
        #expect(second.revision == 2)
        #expect(second.createdAt == first.createdAt)
        #expect(try f.checkIns.history().count == 1)
    }

    @Test func `decision and target must agree, and a failure writes nothing`() throws {
        let f = try Fixture()
        let estimate = try sampleEstimate()
        let target = Target(effectiveFrom: monday, kcal: 1950, macros: MacroTargets(proteinG: 1, carbsG: 1, fatG: 1), origin: .adaptive)
        #expect(throws: Persistence.PersistenceError.self) {
            try f.checkIns.record(estimate: estimate, checkInDay: monday, proposedTargetKcal: 1950, decision: .accepted)
        }
        #expect(throws: Persistence.PersistenceError.self) {
            try f.checkIns.record(
                estimate: estimate,
                checkInDay: monday,
                proposedTargetKcal: 1950,
                decision: .skipped,
                appliedTarget: target,
            )
        }
        #expect(try f.checkIns.history().isEmpty)
        #expect(try f.profiles.targetHistory().isEmpty)
    }

    @Test func `check-ins are exported and restored`() throws {
        let f = try Fixture()
        try f.checkIns.record(estimate: sampleEstimate(), checkInDay: monday, proposedTargetKcal: 1950, decision: .skipped)
        let json = try f.portability.exportJSON()
        let other = try Fixture()
        try other.portability.importJSON(json, mode: .replace)
        #expect(try other.checkIns.history() == f.checkIns.history())
        #expect(try other.portability.exportJSON() == json)
    }
}
