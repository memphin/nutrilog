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

    func calendar(_ identifier: Calendar.Identifier, _ tz: String = "Asia/Bangkok") -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    /// 12:00 on the Gregorian `iso` day in `tz`.
    func noon(_ iso: String, _ tz: String = "Asia/Bangkok") throws -> Date {
        try #require(LocalDay(iso)).date(atHour: 12, calendar: calendar(tz))
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .hebrew, .persian, .japanese, .islamicUmmAlQura, .gregorian])
    func `non-Gregorian device calendars still give the Gregorian day`(identifier: Calendar.Identifier) throws {
        let cal = calendar(identifier)
        // Buddhist 29 Feb 2571 was unparseable; Persian months 2/4/6 have 31 days; 2026-09-01 is Hebrew month 13.
        for iso in ["2028-02-29", "2026-11-11", "2026-05-21", "2026-07-22", "2026-09-22", "2026-09-01", "2024-12-31"] {
            let date = try noon(iso)
            let day = LocalDay(date, calendar: cal)
            #expect(day.isoString == iso)
            #expect(LocalDay(day.isoString) == day) // round-trips through the stored string
            #expect(LocalDay.today(calendar: cal, now: date) == day)
            // Midnight in Bangkok, whatever the calendar system.
            let start = day.startDate(calendar: cal)
            #expect(start == date.addingTimeInterval(-12 * 3600))
            #expect(day.dateInterval(calendar: cal).duration == 86400)
            #expect(day.date(atHour: 12, calendar: cal) == date)
            #expect(day.adding(days: -2) < day)
            let range = day.adding(days: -2) ... day // built like the app does: traps if inverted
            #expect(range.lowerBound.days(until: range.upperBound) == 2)
            #expect(day.weekday == calendar("UTC").component(.weekday, from: try noon(iso, "UTC")))
        }
    }

    @Test func `Hebrew month 13 and Buddhist years no longer leak into the day`() throws {
        // 2026-09-01 is 19 Elul 5786, which Foundation numbers month 13; 2026 is Buddhist year 2569.
        let date = try noon("2026-09-01")
        let hebrew = LocalDay(date, calendar: calendar(.hebrew))
        #expect(hebrew.isoString == "2026-09-01")
        #expect(hebrew.adding(days: -2).isoString == "2026-08-30")
        #expect(LocalDay(date, calendar: calendar(.buddhist)).year == 2026)
        #expect(LocalDay(date, calendar: calendar(.japanese)).year == 2026)
    }

    @Test func `time zone of a non-Gregorian calendar is honoured`() {
        // 2026-11-09T23:30Z is already the 10th in Zagreb.
        let date = Date(timeIntervalSince1970: 1_794_267_000)
        #expect(LocalDay(date, calendar: calendar(.buddhist, "UTC")).isoString == "2026-11-09")
        #expect(LocalDay(date, calendar: calendar(.buddhist, "Europe/Zagreb")).isoString == "2026-11-10")
    }
}
