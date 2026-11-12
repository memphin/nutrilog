import Foundation
import Testing
@testable import Core

struct StreakTests {
    let today = LocalDay("2026-11-11")!

    func streak(_ reachedOffsets: Set<Int>, maxDays: Int = 60) -> Streak {
        Streak.current(today: today, maxDays: maxDays) { reachedOffsets.contains($0.days(until: today)) }
    }

    @Test func `no reached days is no streak`() {
        let s = streak([])
        #expect(s.days == 0)
        #expect(!s.includesToday)
    }

    @Test func `today reached counts today and the days before it`() {
        let s = streak([0, 1, 2])
        #expect(s.days == 3)
        #expect(s.includesToday)
    }

    @Test func `today not reached yet keeps the streak up to yesterday`() {
        let s = streak([1, 2, 3, 4])
        #expect(s.days == 4)
        #expect(!s.includesToday)
    }

    @Test func `a missed day ends the streak`() {
        #expect(streak([0, 1, 3, 4]).days == 2)
        #expect(streak([2, 3]).days == 0)
    }

    @Test func `counting stops at the limit`() {
        let s = streak(Set(0 ..< 100), maxDays: 60)
        #expect(s.days == 60)
        #expect(s.isAtLimit)
        #expect(!streak([0, 1]).isAtLimit)
    }

    @Test func `only today reached is a one-day streak`() {
        #expect(streak([0]) == Streak(days: 1, includesToday: true, isAtLimit: false))
    }

    // MARK: Today final once recorded (sleep)

    func finalStreak(_ reachedOffsets: Set<Int>, todayIsFinal: Bool) -> Streak {
        Streak.current(today: today, maxDays: 60, todayIsFinal: todayIsFinal) { reachedOffsets.contains($0.days(until: today)) }
    }

    @Test func `final today reached counts today`() {
        #expect(finalStreak([0, 1, 2], todayIsFinal: true) == Streak(days: 3, includesToday: true, isAtLimit: false))
    }

    @Test func `final today missed breaks the streak`() {
        #expect(finalStreak([1, 2, 3], todayIsFinal: true) == .none)
    }

    @Test func `today not final yet keeps the streak up to yesterday`() {
        #expect(finalStreak([1, 2, 3], todayIsFinal: false) == Streak(days: 3, includesToday: false, isAtLimit: false))
    }

    @Test func `today is not final by default`() {
        // Steps and water: a running day never breaks the streak.
        #expect(streak([1, 2]) == finalStreak([1, 2], todayIsFinal: false))
        #expect(streak([1, 2]).days == 2)
    }
}
