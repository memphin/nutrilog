import Foundation
import Testing
@testable import Core

struct SleepAggregatorTests {
    let zagreb = HealthFixtures.zagreb
    let night = day("2026-11-09")

    @Test func `watch night with stages`() throws {
        let summary = try #require(SleepAggregator.aggregate(samples: watchNight(), for: night, calendar: zagreb))
        #expect(summary.night == night)
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.asleepMinutes == 465)
        #expect(summary.inBedMinutes == 480)
        #expect(summary.minutes(\.core) == 330)
        #expect(summary.minutes(\.deep) == 60)
        #expect(summary.minutes(\.rem) == 75)
        #expect(summary.minutes(\.awake) == 15)
        #expect(summary.minutes(\.unspecified) == 0)
        #expect(summary.hasStages)
    }

    @Test func `overlapping samples of one source count once`() throws {
        let samples = [
            sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 01:00"),
            sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 01:00"), // exact duplicate
            sleep(.asleepCore, "2026-11-09 00:30", "2026-11-09 01:30"), // overlaps the first and the deep sample
            sleep(.asleepDeep, "2026-11-09 01:00", "2026-11-09 02:00"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.asleepMinutes == 180) // 23:00–02:00, not 120 + 120 + 60 + 60
        #expect(summary.inBedMinutes == 180)
        #expect(summary.minutes(\.core) == 120) // 01:00–01:30 goes to the deeper stage
        #expect(summary.minutes(\.deep) == 60)
    }

    @Test func `stage breakdown never exceeds time asleep`() throws {
        // Awake overlapping an asleep stage of the same source counts as asleep; in-bed covers everything once.
        let samples = [
            sleep(.inBed, "2026-11-08 22:30", "2026-11-09 07:30"),
            sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 03:00"),
            sleep(.awake, "2026-11-09 02:30", "2026-11-09 03:30"),
            sleep(.asleepREM, "2026-11-09 03:30", "2026-11-09 07:00"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        let asleep = try #require(summary.asleep)
        let stages = summary.core + summary.deep + summary.rem + summary.unspecified
        #expect(stages == asleep)
        #expect(summary.asleepMinutes == 450) // 23:00–03:00 + 03:30–07:00
        #expect(summary.minutes(\.awake) == 30) // 03:00–03:30 only
        #expect(summary.inBedMinutes == 540) // 22:30–07:30
        #expect(asleep + summary.awake <= summary.inBed)
    }

    @Test func `in bed sample spanning the night does not inflate totals`() throws {
        let samples = watchNight() + [sleep(.inBed, "2026-11-08 22:30", "2026-11-09 07:30")]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.asleepMinutes == 465)
        #expect(summary.inBedMinutes == 540)
        #expect(summary.minutes(\.awake) == 15)
    }

    @Test func `iPhone in bed estimate is ignored when the watch has data`() throws {
        let phone = sleep(.inBed, "2026-11-08 22:00", "2026-11-09 08:00", HealthFixtures.iPhone)
        let summary = try #require(SleepAggregator.aggregate(samples: watchNight() + [phone], for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.inBedMinutes == 480) // the watch's 23:00–07:00, not the phone's 10 h
        #expect(summary.asleepMinutes == 465)
    }

    @Test func `iPhone only night falls back to the in bed estimate`() throws {
        let phone = sleep(.inBed, "2026-11-08 22:00", "2026-11-09 08:00", HealthFixtures.iPhone)
        let summary = try #require(SleepAggregator.aggregate(samples: [phone], for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.iPhone)
        #expect(summary.asleep == nil) // the phone does not know when you slept
        #expect(summary.inBedMinutes == 600)
        #expect(!summary.hasStages)
    }

    @Test func `multi source double counting is impossible`() throws {
        let app = [sleep(.asleepUnspecified, "2026-11-08 22:45", "2026-11-09 07:15", HealthFixtures.sleepApp)]
        let phone = [sleep(.inBed, "2026-11-08 22:00", "2026-11-09 08:00", HealthFixtures.iPhone)]
        let all = watchNight() + app + phone + watchNight() // the watch night twice, too
        let summary = try #require(SleepAggregator.aggregate(samples: all, for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.asleepMinutes == 465)
        #expect(summary.inBedMinutes == 480)
        #expect(summary.minutes(\.unspecified) == 0)

        // Without the watch, another app beats the iPhone estimate.
        let fallback = try #require(SleepAggregator.aggregate(samples: app + phone, for: night, calendar: zagreb))
        #expect(fallback.source == HealthFixtures.sleepApp)
        #expect(fallback.asleepMinutes == 510)
        #expect(fallback.inBedMinutes == 510)
        #expect(!fallback.hasStages)
    }

    @Test func `a third-party watch app is not treated as Apple Watch`() throws {
        // The watch app reports more sleep, but only Apple's own watch source has priority.
        let watchApp = [sleep(.asleepUnspecified, "2026-11-08 22:00", "2026-11-09 08:00", HealthFixtures.watchSleepApp)]
        let summary = try #require(SleepAggregator.aggregate(samples: watchApp + watchNight(), for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.asleepMinutes == 465)

        // Without Apple Watch data it is an ordinary app source and still beats the iPhone estimate.
        let phone = [sleep(.inBed, "2026-11-08 21:00", "2026-11-09 09:00", HealthFixtures.iPhone)]
        let fallback = try #require(SleepAggregator.aggregate(samples: watchApp + phone, for: night, calendar: zagreb))
        #expect(fallback.source == HealthFixtures.watchSleepApp)
        #expect(fallback.asleepMinutes == 600)
    }

    @Test func `other sources let awake cut into an unspecified asleep block`() throws {
        let samples = [
            sleep(.asleepUnspecified, "2026-11-08 23:00", "2026-11-09 07:00", HealthFixtures.sleepApp),
            sleep(.awake, "2026-11-09 03:00", "2026-11-09 03:30", HealthFixtures.sleepApp),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.sleepApp)
        #expect(summary.asleepMinutes == 450)
        #expect(summary.minutes(\.unspecified) == 450)
        #expect(summary.minutes(\.awake) == 30)
        #expect(summary.inBedMinutes == 480)
    }

    @Test func `the Apple Watch keeps unspecified asleep over an overlapping awake sample`() throws {
        let samples = [
            sleep(.asleepUnspecified, "2026-11-08 23:00", "2026-11-09 07:00"),
            sleep(.awake, "2026-11-09 03:00", "2026-11-09 03:30"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.asleepMinutes == 480)
        #expect(summary.minutes(\.awake) == 0)
        #expect(summary.inBedMinutes == 480)
    }

    @Test func `two watches pick the one that slept longer, never the sum`() throws {
        let shorter = [sleep(.asleepCore, "2026-11-09 01:00", "2026-11-09 07:00", HealthFixtures.oldWatch)]
        let summary = try #require(SleepAggregator.aggregate(samples: shorter + watchNight(), for: night, calendar: zagreb))
        #expect(summary.source == HealthFixtures.watch)
        #expect(summary.asleepMinutes == 465)

        // Equal time asleep: the choice is still deterministic.
        let twin = watchNight(HealthFixtures.oldWatch)
        let first = SleepAggregator.aggregate(samples: twin + watchNight(), for: night, calendar: zagreb)
        let second = SleepAggregator.aggregate(samples: watchNight() + twin, for: night, calendar: zagreb)
        #expect(first == second)
        #expect(first?.asleepMinutes == 465)
    }

    @Test func `naps count toward the day they end on before 18 00`() throws {
        let afternoonNap = sleep(.asleepCore, "2026-11-09 14:00", "2026-11-09 15:00")
        let eveningNap = sleep(.asleepCore, "2026-11-09 19:00", "2026-11-09 20:00")
        let samples = watchNight() + [afternoonNap, eveningNap]

        let today = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(today.asleepMinutes == 525) // 465 + the afternoon nap
        #expect(today.inBedMinutes == 540)

        let tomorrow = try #require(SleepAggregator.aggregate(samples: samples, for: night.next, calendar: zagreb))
        #expect(tomorrow.asleepMinutes == 60) // the evening nap belongs to the next night
    }

    @Test func `night window boundaries use the sample end`() throws {
        let window = SleepAggregator.nightWindow(for: night, calendar: zagreb)
        #expect(window.start == time("2026-11-08 18:00"))
        #expect(window.end == time("2026-11-09 18:00"))

        let endsAtBoundary = sleep(.asleepCore, "2026-11-09 17:00", "2026-11-09 18:00")
        let endsJustAfter = sleep(.asleepCore, "2026-11-09 17:00", "2026-11-09 18:00:01")
        let straddlesStart = sleep(.asleepCore, "2026-11-08 17:00", "2026-11-08 18:30")
        let endsAtPreviousBoundary = sleep(.asleepCore, "2026-11-08 17:30", "2026-11-08 18:00")
        let samples = [endsAtBoundary, endsJustAfter, straddlesStart, endsAtPreviousBoundary]

        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.asleepMinutes == 150) // 60 (ends at 18:00) + 90 (whole sample, ends after 18:00 D-1)
        #expect(SleepAggregator.night(endingAt: time("2026-11-09 18:00"), calendar: zagreb) == night)
        #expect(SleepAggregator.night(endingAt: time("2026-11-09 18:00:01"), calendar: zagreb) == night.next)
        #expect(SleepAggregator.night(endingAt: time("2026-11-09 03:00"), calendar: zagreb) == night)
        #expect(SleepAggregator.night(endingAt: time("2026-11-08 23:59"), calendar: zagreb) == night)
    }

    @Test func `spring DST night counts real elapsed time`() throws {
        // 2026-03-29 in Zagreb: clocks jump 02:00 → 03:00, so 23:00 → 07:00 on the wall is 7 h asleep.
        let springNight = day("2026-03-29")
        let window = SleepAggregator.nightWindow(for: springNight, calendar: zagreb)
        #expect(window.duration == 82800) // 23 h
        let samples = [
            sleep(.asleepCore, "2026-03-28 23:00", "2026-03-29 01:30"),
            sleep(.asleepDeep, "2026-03-29 01:30", "2026-03-29 03:30"), // 01:30 → 03:30 wall = 1 h
            sleep(.asleepCore, "2026-03-29 03:30", "2026-03-29 07:00"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: springNight, calendar: zagreb))
        #expect(summary.asleepMinutes == 420)
        #expect(summary.minutes(\.deep) == 60)
        #expect(summary.inBedMinutes == 420)
    }

    @Test func `autumn DST night counts real elapsed time`() throws {
        // 2026-10-25 in Zagreb: clocks fall back 03:00 → 02:00, so 23:00 → 07:00 on the wall is 9 h.
        let autumnNight = day("2026-10-25")
        let window = SleepAggregator.nightWindow(for: autumnNight, calendar: zagreb)
        #expect(window.duration == 90000) // 25 h
        let samples = [sleep(.asleepCore, "2026-10-24 23:00", "2026-10-25 07:00")]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: autumnNight, calendar: zagreb))
        #expect(summary.asleepMinutes == 540)
        // A sample ending at 17:30 on the DST day is still inside the 25 h window.
        let lateNap = sleep(.asleepCore, "2026-10-25 17:00", "2026-10-25 17:30")
        let withNap = try #require(SleepAggregator.aggregate(samples: samples + [lateNap], for: autumnNight, calendar: zagreb))
        #expect(withNap.asleepMinutes == 570)
    }

    @Test func `the same samples fall into different nights in another time zone`() throws {
        // 2026-11-09 18:30 in Zagreb is 12:30 in New York: next night in Zagreb, a nap in New York.
        let sample = sleep(.asleepCore, "2026-11-09 17:30", "2026-11-09 18:30")
        #expect(SleepAggregator.aggregate(samples: [sample], for: night, calendar: zagreb) == nil)
        let newYork = try #require(SleepAggregator.aggregate(samples: [sample], for: night, calendar: HealthFixtures.newYork))
        #expect(newYork.asleepMinutes == 60)
    }

    @Test func `empty and invalid samples give no summary`() {
        #expect(SleepAggregator.aggregate(samples: [], for: night, calendar: zagreb) == nil)
        let zeroLength = sleep(.asleepCore, "2026-11-09 03:00", "2026-11-09 03:00")
        let backwards = sleep(.asleepCore, "2026-11-09 04:00", "2026-11-09 03:00")
        #expect(SleepAggregator.aggregate(samples: [zeroLength, backwards], for: night, calendar: zagreb) == nil)
        let otherNight = sleep(.asleepCore, "2026-11-07 23:00", "2026-11-08 07:00")
        #expect(SleepAggregator.aggregate(samples: [otherNight], for: night, calendar: zagreb) == nil)
    }

    @Test func `aggregate over a range of nights`() {
        let samples = watchNight() + [
            sleep(.asleepCore, "2026-11-09 23:30", "2026-11-10 06:30"),
            sleep(.asleepCore, "2026-11-11 23:00", "2026-11-12 06:00"), // outside the range
        ]
        let nights = SleepAggregator.aggregate(samples: samples, nights: night ... night.next, calendar: zagreb)
        #expect(nights.count == 2)
        #expect(nights[night]?.asleepMinutes == 465)
        #expect(nights[night.next]?.asleepMinutes == 420)
        #expect(nights[day("2026-11-12")] == nil)
    }

    @Test func `woke at is the end of the last asleep sample before noon`() throws {
        let samples = [
            sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 06:40"),
            sleep(.awake, "2026-11-09 06:40", "2026-11-09 06:50"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.wokeAt == time("2026-11-09 06:40")) // the awake sample after it does not count
    }

    @Test func `an afternoon nap does not move woke at`() throws {
        let samples = [
            sleep(.asleepCore, "2026-11-08 23:00", "2026-11-09 06:40"),
            sleep(.awake, "2026-11-09 06:40", "2026-11-09 06:50"),
            sleep(.asleepCore, "2026-11-09 14:00", "2026-11-09 14:30"),
        ]
        let summary = try #require(SleepAggregator.aggregate(samples: samples, for: night, calendar: zagreb))
        #expect(summary.wokeAt == time("2026-11-09 06:40"))
    }

    @Test func `no asleep samples means no woke at`() throws {
        let phone = sleep(.inBed, "2026-11-08 22:00", "2026-11-09 08:00", HealthFixtures.iPhone)
        let summary = try #require(SleepAggregator.aggregate(samples: [phone], for: night, calendar: zagreb))
        #expect(summary.wokeAt == nil)
    }

    @Test func `apply sleep copies woke at`() {
        let wokeAt = time("2026-11-09 06:40")
        let summary = SleepSummary(night: night, source: HealthFixtures.watch, asleep: 27600, inBed: 27600, wokeAt: wokeAt)
        var metrics = DailyHealthMetrics(day: night)
        metrics.apply(sleep: summary)
        #expect(metrics.wokeAt == wokeAt)
    }
}

struct HealthSourceTests {
    @Test func `source kinds`() {
        #expect(HealthFixtures.watch.kind == .appleWatch)
        #expect(HealthFixtures.iPhone.kind == .iPhone)
        #expect(HealthFixtures.withings.kind == .app)
        #expect(HealthFixtures.healthApp.kind == .app) // manual entries in the Health app
        #expect(HealthFixtures.watchSleepApp.kind == .app) // third-party app on the watch
        #expect(HealthSource(name: "?", bundleIdentifier: "com.apple.health.X").kind == .iPhone)
        #expect(HealthSource(name: "?", bundleIdentifier: "x").kind == .app)
        #expect(HealthSourceKind.appleWatch < .app)
        #expect(HealthSourceKind.app < .iPhone)
    }

    @Test func `main source of a statistic`() {
        let stat = CumulativeStatistic(
            start: .distantPast, end: .distantFuture, sum: 8000,
            sources: [
                SourceContribution(source: HealthFixtures.iPhone, sum: 3000),
                SourceContribution(source: HealthFixtures.watch, sum: 7000),
            ],
        )
        #expect(stat.mainSource == HealthFixtures.watch)
        #expect(CumulativeStatistic(start: .distantPast, end: .distantFuture, sum: 1).mainSource == nil)
        let tie = CumulativeStatistic(
            start: .distantPast, end: .distantFuture, sum: 2,
            sources: [
                SourceContribution(source: HealthFixtures.withings, sum: 1),
                SourceContribution(source: HealthFixtures.healthApp, sum: 1),
            ],
        )
        #expect(tie.mainSource == HealthFixtures.healthApp) // "Health" < "Withings"
    }

    @Test func `sleep stages`() {
        let asleep = SleepStage.allCases.filter(\.isAsleep)
        #expect(asleep == [.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM])
    }
}
