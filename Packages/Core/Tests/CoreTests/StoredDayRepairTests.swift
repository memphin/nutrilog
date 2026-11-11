import Foundation
import Testing
@testable import Core

struct StoredDayRepairTests {
    static let today = LocalDay(year: 2026, month: 11, day: 11)!
    let activity = StoredDayRepair.Scope.activity(today: Self.today)
    let birth = StoredDayRepair.Scope.birthDate(today: Self.today)

    func repaired(_ stored: String, _ device: Calendar.Identifier, scope: StoredDayRepair.Scope? = nil) -> String? {
        StoredDayRepair.repairedDay(stored, deviceCalendar: device, scope: scope ?? activity)?.isoString
    }

    // MARK: Device calendar says which

    @Test(arguments: [
        ("2569-11-11", Calendar.Identifier.buddhist, "2026-11-11"),
        ("2567-02-29", .buddhist, "2024-02-29"),
        ("0008-11-11", .japanese, "2026-11-11"),
        ("0002-01-01", .japanese, "2020-01-01"),
        ("1405-08-20", .persian, "2026-11-11"),
        ("1405-06-31", .persian, "2026-09-22"), // 31-day Persian month
        ("1398-10-11", .persian, "2020-01-01"),
        ("5786-13-19", .hebrew, "2026-09-01"), // Elul is month 13 in Foundation's numbering
        ("5787-03-01", .hebrew, "2026-11-11"),
        ("0115-11-11", .republicOfChina, "2026-11-11"),
        ("1448-06-01", .islamicUmmAlQura, "2026-11-11"),
        ("1448-05-20", .islamicCivil, "2026-11-01"), // the device names the variant, a day off Umm al-Qura
        ("1448-05-20", .islamicTabular, "2026-10-31"),
        ("1948-08-20", .indian, "2026-11-11"),
        ("1743-03-02", .coptic, "2026-11-11"),
        ("2570-11-11", .buddhist, "2027-11-11"), // a plan up to ~400 days ahead is plausible
    ])
    func `converts from the device calendar`(stored: String, device: Calendar.Identifier, expected: String) {
        #expect(repaired(stored, device) == expected)
    }

    // MARK: Device calendar Gregorian now (the user switched back) → inferred from the year

    @Test(arguments: [
        ("2569-11-11", "2026-11-11"), // Buddhist
        ("0115-11-11", "2026-11-11"), // Republic of China
        ("0008-11-11", "2026-11-11"), // Japanese, Reiwa
        ("1405-06-31", "2026-09-22"), // Persian
        ("5786-13-19", "2026-09-01"), // Hebrew
        ("1448-06-01", "2026-11-11"), // Umm al-Qura
        ("1448-05-20", "2026-10-31"), // an Islamic year without a device variant: Umm al-Qura
        ("1405-02-10", "2026-04-30"), // Persian; the Umm al-Qura reading (1984) is implausible
    ])
    func `infers the calendar on a gregorian device`(stored: String, expected: String) {
        #expect(repaired(stored, .gregorian) == expected)
        #expect(repaired(stored, .iso8601) == expected)
    }

    @Test func `converts a leap day that is no gregorian date`() {
        // Gregorian 2571 is no leap year, so "2571-02-29" doesn't even parse; Buddhist 2571 is 2028, a leap year.
        let later = StoredDayRepair.Scope.activity(today: LocalDay(year: 2028, month: 3, day: 1)!)
        #expect(LocalDay("2571-02-29") == nil)
        #expect(repaired("2571-02-29", .buddhist, scope: later) == "2028-02-29")
        #expect(repaired("2571-02-29", .gregorian, scope: later) == "2028-02-29")
        // Seen from 2026-11-11 it is more than 400 days ahead: implausible, left alone.
        #expect(repaired("2571-02-29", .buddhist) == nil)
    }

    @Test func `falls back to inference when the triple does not fit the device calendar`() {
        // Device Persian now, but this row was written while it was Buddhist.
        #expect(repaired("2569-11-11", .persian) == "2026-11-11")
        // Device Japanese, a Hebrew row.
        #expect(repaired("5787-03-01", .japanese) == "2026-11-11")
    }

    // MARK: Never touched

    @Test(arguments: [Calendar.Identifier.gregorian, .buddhist, .japanese, .persian, .hebrew, .islamicUmmAlQura,
                      .republicOfChina, .ethiopicAmeteMihret, .chinese])
    func `gregorian years are never touched`(device: Calendar.Identifier) {
        for stored in ["2000-01-01", "2026-11-11", "2028-02-29", "2200-12-31", "2019-03-02"] {
            #expect(repaired(stored, device) == nil)
        }
    }

    @Test(arguments: [
        ("2569-11-11", Calendar.Identifier.chinese), // cyclic year calendars: nothing is guessed
        ("0043-09-21", .chinese),
        ("0008-11-11", .chinese), // looks like Reiwa 8 but may be a Chinese cycle year
        ("1405-07-31", .persian), // not a Persian date (month 7 has 30 days) and no other calendar fits
        ("1405-07-31", .gregorian),
        ("5786-06-01", .hebrew), // 5786 is not a leap year: no Adar I
        ("2571-02-30", .buddhist),
        ("1999-12-31", .gregorian), // implausible in every calendar
        ("0150-01-01", .gregorian), // ROC 150 = 2061, too far ahead
        ("0001-01-01", .japanese), // Reiwa 1 = 2019, before the app window
        ("9999-99-99", .buddhist),
        ("2569-00-11", .buddhist),
        ("2569-11-00", .buddhist),
    ])
    func `returns nil when not certain`(stored: String, device: Calendar.Identifier) {
        #expect(repaired(stored, device) == nil)
    }

    @Test(arguments: ["", "2569-11-1", "2569/11/11", "2569-11-11 ", "x569-11-11", "+569-11-11", "25691-1-11"])
    func `rejects malformed strings`(stored: String) {
        #expect(repaired(stored, .buddhist) == nil)
    }

    @Test func `ethiopic years look gregorian and are left alone`() {
        // Ethiopic 2019-03-02 is Gregorian 2026-11-11, but 2019 is inside the Gregorian years: never guessed.
        #expect(repaired("2019-03-02", .ethiopicAmeteMihret) == nil)
        // Amete Alem years (7519) don't look Gregorian, but Foundation converts them differently between OS
        // versions, so they are never repaired either.
        #expect(repaired("7519-03-02", .ethiopicAmeteAlem) == nil)
        #expect(repaired("7519-03-02", .gregorian) == nil)
    }

    @Test func `is idempotent`() {
        for (stored, device) in [("2569-11-11", Calendar.Identifier.buddhist), ("1405-06-31", .persian), ("0008-11-11", .japanese)] {
            let once = try! #require(repaired(stored, device))
            #expect(repaired(once, device) == nil)
            #expect(repaired(once, .gregorian) == nil)
        }
    }

    // MARK: Birth dates

    @Test func `birth dates use their own window`() {
        #expect(repaired("2533-05-01", .buddhist, scope: birth) == "1990-05-01")
        #expect(repaired("2533-05-01", .gregorian, scope: birth) == "1990-05-01")
        #expect(repaired("1369-02-11", .persian, scope: birth) == "1990-05-01")
        #expect(repaired("0079-05-01", .republicOfChina, scope: birth) == "1990-05-01")
        // Persian 1369 and Umm al-Qura 1369 (1950) are both plausible birth years: without the device calendar, nil.
        #expect(repaired("1369-02-11", .gregorian, scope: birth) == nil)
        // Japanese: Heisei 2 (1990) or Reiwa 2 (2020)? Ambiguous.
        #expect(repaired("0002-05-01", .japanese, scope: birth) == nil)
        // A Gregorian birth date is never touched, even where another calendar would read it as plausible.
        #expect(repaired("1990-05-01", .ethiopicAmeteMihret, scope: birth) == nil)
        #expect(repaired("1950-03-10", .persian, scope: birth) == nil)
        // The activity window would reject a 1990 day.
        #expect(repaired("2533-05-01", .buddhist) == nil)
    }

    // MARK: JSON

    @Test func `repairs day strings inside JSON and nothing else`() {
        let json = #"{"day":"2569-11-10","days":[{"day":"2569-11-04","kcalIn":2000}],"note":"\"2569-11-10\" stays","trendStartDay":"2026-11-03","x":"2569-11-10T00:00:00Z"}"#
        let repaired = StoredDayRepair.repairingDays(inJSON: json, deviceCalendar: .buddhist, scope: activity)
        #expect(repaired == #"{"day":"2026-11-10","days":[{"day":"2026-11-04","kcalIn":2000}],"note":"\"2569-11-10\" stays","trendStartDay":"2026-11-03","x":"2569-11-10T00:00:00Z"}"#)
        #expect(StoredDayRepair.repairingDays(inJSON: repaired!, deviceCalendar: .buddhist, scope: activity) == nil)
        #expect(StoredDayRepair.repairingDays(inJSON: #""2569-11-10""#, deviceCalendar: .buddhist, scope: activity) == #""2026-11-10""#)
        #expect(StoredDayRepair.repairingDays(inJSON: #"{"a":1}"#, deviceCalendar: .buddhist, scope: activity) == nil)
        #expect(StoredDayRepair.repairingDays(inJSON: "", deviceCalendar: .buddhist, scope: activity) == nil)
    }
}
