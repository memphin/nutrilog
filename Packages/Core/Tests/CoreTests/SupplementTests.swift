import Foundation
import Testing
@testable import Core

struct SupplementScheduleTests {
    // 2026-11-09 is a Monday (weekday 2).
    let monday = LocalDay("2026-11-09")!

    @Test func `times are sorted, unique and within the day`() {
        let schedule = SupplementSchedule(times: [1260, 480, 480, -5, 1440], weekdays: [0, 2, 9])
        #expect(schedule.times == [480, 1260])
        #expect(schedule.weekdays == [2])
        #expect(!schedule.isAsNeeded)
        #expect(SupplementSchedule.asNeeded.isAsNeeded)
    }

    @Test func `every day or only on the chosen weekdays`() {
        let daily = SupplementSchedule(times: [480])
        #expect(daily.isEveryDay)
        #expect(daily.times(on: monday) == [480])
        #expect(daily.times(on: monday.next) == [480])
        let mondays = SupplementSchedule(times: [480], weekdays: [2])
        #expect(mondays.times(on: monday) == [480])
        #expect(mondays.times(on: monday.next).isEmpty)
        #expect(SupplementSchedule(times: [480], weekdays: Set(1 ... 7)).isEveryDay)
    }

    @Test func `slot date is the local time of the day`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Zagreb"))
        let date = SupplementSlot(day: monday, minute: 8 * 60 + 30).date(calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts == DateComponents(year: 2026, month: 11, day: 9, hour: 8, minute: 30))
    }
}

struct SupplementReminderPlannerTests {
    let monday = LocalDay("2026-11-09")!
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        return calendar
    }()

    func item(_ id: String, _ times: [Int], weekdays: Set<Int> = [], start: LocalDay? = nil) -> SupplementReminderPlanner.Item {
        .init(id: id, name: id, dose: "1", schedule: SupplementSchedule(times: times, weekdays: weekdays), startDay: start ?? monday.adding(days: -30))
    }

    func at(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Date {
        SupplementSlot(day: day, minute: hour * 60 + minute).date(calendar: calendar)
    }

    @Test func `doses at the same time share one reminder and its follow-up`() {
        let plan = SupplementReminderPlanner.plan(
            items: [item("d3", [480]), item("omega", [480])], handled: [], now: at(monday, 7), calendar: calendar, horizonDays: 1,
        )
        #expect(plan.map(\.kind) == [.due, .followUp])
        #expect(plan[0].fireDate == at(monday, 8))
        #expect(plan[1].fireDate == at(monday, 9))
        #expect(plan[0].items.map(\.id) == ["d3", "omega"])
    }

    @Test func `taken or skipped doses are not reminded`() {
        let slot = SupplementSlot(day: monday, minute: 480)
        let plan = SupplementReminderPlanner.plan(
            items: [item("d3", [480]), item("omega", [480])],
            handled: [SupplementDoseKey(supplementID: "d3", slot: slot)],
            now: at(monday, 7), calendar: calendar, horizonDays: 1,
        )
        #expect(plan.allSatisfy { $0.items.map(\.id) == ["omega"] })
        let none = SupplementReminderPlanner.plan(
            items: [item("d3", [480])], handled: [SupplementDoseKey(supplementID: "d3", slot: slot)],
            now: at(monday, 7), calendar: calendar, horizonDays: 1,
        )
        #expect(none.isEmpty)
    }

    @Test func `a missed dose still gets its follow-up`() {
        let plan = SupplementReminderPlanner.plan(items: [item("d3", [480])], handled: [], now: at(monday, 8, 30), calendar: calendar, horizonDays: 1)
        #expect(plan.map(\.kind) == [.followUp])
        let late = SupplementReminderPlanner.plan(items: [item("d3", [480])], handled: [], now: at(monday, 9, 1), calendar: calendar, horizonDays: 1)
        #expect(late.isEmpty)
    }

    @Test func `a snoozed slot gets one reminder at the snooze time instead`() {
        let slot = SupplementSlot(day: monday, minute: 480)
        let plan = SupplementReminderPlanner.plan(
            items: [item("d3", [480])], handled: [], snoozed: [slot: at(monday, 8, 15)], now: at(monday, 8, 1),
            calendar: calendar, horizonDays: 1,
        )
        #expect(plan.map(\.kind) == [.snoozed])
        #expect(plan[0].fireDate == at(monday, 8, 15))
        // A snooze that has passed counts no more.
        let passed = SupplementReminderPlanner.plan(
            items: [item("d3", [480])], handled: [], snoozed: [slot: at(monday, 8, 15)], now: at(monday, 8, 20),
            calendar: calendar, horizonDays: 1,
        )
        #expect(passed.map(\.kind) == [.followUp])
    }

    @Test func `plans the next days on their weekdays, from the start day, up to the limit`() {
        let plan = SupplementReminderPlanner.plan(
            items: [item("mon", [480], weekdays: [2]), item("new", [1200], start: monday.adding(days: 2))],
            handled: [], now: at(monday, 0), calendar: calendar,
        )
        #expect(plan.filter { $0.kind == .due && $0.items.map(\.id) == ["mon"] }.map(\.slot.day) == [monday])
        #expect(plan.filter { $0.kind == .due && $0.items.map(\.id) == ["new"] }.map(\.slot.day) == (2 ..< 7).map { monday.adding(days: $0) })
        #expect(plan.map(\.fireDate) == plan.map(\.fireDate).sorted())

        let many = (0 ..< 10).map { item("s\($0)", [$0 * 60]) }
        let capped = SupplementReminderPlanner.plan(items: many, handled: [], now: at(monday, 0), calendar: calendar)
        #expect(capped.count == SupplementReminderPlanner.limit)
        #expect(capped.first?.fireDate == at(monday, 1)) // 00:00 itself is not after now
    }

    @Test func `as-needed supplements are never reminded`() {
        let plan = SupplementReminderPlanner.plan(
            items: [.init(id: "ibu", name: "Ibuprofen", dose: "400 mg", schedule: .asNeeded, startDay: monday)],
            handled: [], now: at(monday, 0), calendar: calendar,
        )
        #expect(plan.isEmpty)
    }
}
