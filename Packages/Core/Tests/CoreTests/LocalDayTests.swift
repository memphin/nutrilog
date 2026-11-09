import Foundation
import Testing
@testable import Core

struct LocalDayTests {
    func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    @Test func `parses and formats`() throws {
        let day = try #require(LocalDay("2026-11-09"))
        #expect(day.year == 2026 && day.month == 11 && day.day == 9)
        #expect(day.isoString == "2026-11-09")
        #expect(day.description == "2026-11-09")
    }

    @Test(arguments: ["2026-02-30", "2026-13-01", "26-11-09", "2026-1-9", "abc", "2026-11-09-01"])
    func `rejects invalid`(input: String) {
        #expect(LocalDay(input) == nil)
    }

    @Test func `day from date uses time zone`() {
        // 2026-11-09 23:30 UTC is already 2026-11-10 in Zagreb (UTC+1).
        let date = Date(timeIntervalSince1970: 1_794_267_000) // 2026-11-09T23:30:00Z
        #expect(LocalDay(date, calendar: calendar("UTC")).isoString == "2026-11-09")
        #expect(LocalDay(date, calendar: calendar("Europe/Zagreb")).isoString == "2026-11-10")
    }

    @Test func `arithmetic across months years and leap days`() throws {
        let d = try #require(LocalDay("2028-02-28"))
        #expect(d.next.isoString == "2028-02-29")
        #expect(d.adding(days: 2).isoString == "2028-03-01")
        #expect(try #require(LocalDay("2026-12-31")).next.isoString == "2027-01-01")
        #expect(try #require(LocalDay("2026-01-01")).previous.isoString == "2025-12-31")
        #expect(d.days(until: d.adding(days: 30)) == 30)
        #expect(d.adding(days: 30).days(until: d) == -30)
    }

    @Test func `dst days have correct boundaries`() throws {
        let zagreb = calendar("Europe/Zagreb")
        // 2026-03-29: clocks jump forward → day is 23 h long. 2026-10-25: 25 h.
        let spring = try #require(LocalDay("2026-03-29"))
        let autumn = try #require(LocalDay("2026-10-25"))
        #expect(spring.next.startDate(calendar: zagreb).timeIntervalSince(spring.startDate(calendar: zagreb)) == 23 * 3600)
        #expect(autumn.next.startDate(calendar: zagreb).timeIntervalSince(autumn.startDate(calendar: zagreb)) == 25 * 3600)
        #expect(spring.next.isoString == "2026-03-30")
    }

    @Test func `comparable and weekday`() throws {
        let mon = try #require(LocalDay("2026-11-09"))
        #expect(mon.weekday == 2) // Monday
        #expect(mon.next.weekday == 3)
        #expect(mon < mon.next)
        #expect(!(mon < mon))
        #expect([mon.next, mon].sorted() == [mon, mon.next])
    }

    @Test func `codable as plain string`() throws {
        let day = try #require(LocalDay("2026-11-09"))
        let data = try JSONEncoder().encode([day])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2026-11-09\"]")
        #expect(try JSONDecoder().decode([LocalDay].self, from: data) == [day])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([LocalDay].self, from: Data("[\"nope\"]".utf8))
        }
    }

    @Test func today() {
        let utc = calendar("UTC")
        let now = Date(timeIntervalSince1970: 0)
        #expect(LocalDay.today(calendar: utc, now: now).isoString == "1970-01-01")
    }
}
