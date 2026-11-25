import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

#if !WINDOW_CORE_TESTS
@main
#endif
struct EveningCoreTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(name)") }
    }
    static func main() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func t(_ m: Double) -> Date { date.addingTimeInterval(m * 60) }
        func option(_ start: Double, _ drive: Double) -> DepartureEstimate {
            DepartureEstimate(departure: t(start), driving: drive * 60)
        }
        let early = option(0, 55), later = option(15, 45)
        expect(DeparturePolicy.meaningfulDriving([early, later]) == later, "approved 15 / 10 / 5 tradeoff")
        expect(DeparturePolicy.meaningfulDriving([early, option(15, 48)]) == early, "seven minutes is not meaningful")
        expect(DeparturePolicy.meaningfulDriving([early, option(15, 47)])?.departure == t(15), "eight-minute threshold inclusive")
        expect(DeparturePolicy.meaningfulDriving([early, option(15, 55)]) == early, "flat traffic prefers earlier")
        expect(DeparturePolicy.meaningfulDriving([early, later, option(90, 44)]) == later, "do not wait 75 minutes for a one-minute improvement")
        expect(DeparturePolicy.meaningfulDriving([]) == nil, "no invented estimate")
        expect(DeparturePolicy.meaningfulDriving([option(0, .nan), later]) == later, "invalid estimate filtered")
        let limits = WatchLimits(earliest: t(0), latest: t(60), homeBy: t(120), packing: 300)
        expect(DeparturePolicy.recommend([early, later], limits: limits, now: t(-10), committed: early.departure) == early, "commitment outranks optimization")
        expect(DeparturePolicy.recommend([early, later], limits: limits, now: t(-10), committed: nil) == later, "production default")
        let tight = WatchLimits(earliest: t(0), latest: t(60), homeBy: t(67), packing: 300)
        expect(DeparturePolicy.recommend([early, later], limits: tight, now: t(-10), committed: nil) == early, "do not relax arrival allowance")
        let suite = "window-evening-core-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = JourneyStore(defaults: defaults)
        var usual = SavedJourney(); usual.earliest = 900; store.save(usual)
        var today = usual; today.homeBy = 1200
        store.saveToday(today, on: date)
        expect(store.load().homeBy == usual.homeBy, "today never overwrites legacy usual settings")
        expect(store.loadToday(on: date).homeBy == 1200, "same-day relaunch")
        expect(store.loadToday(on: date.addingTimeInterval(86400)).homeBy == usual.homeBy, "new day uses usual settings")
        usual.appearance = "Dark"; store.save(usual)
        expect(store.loadToday(on: date).appearance == "Dark", "appearance has app lifetime")
        var invalid = today; invalid.packing = -1; store.saveToday(invalid, on: date)
        expect(store.loadToday(on: date).packing == today.packing, "invalid data cannot replace accepted today")
        let batch = TrafficBatch(routeID: "route", checkedAt: date, samples: [early, later])
        let offer = DepartureOffer(choice: later, baseline: early, batch: batch, limits: limits)
        expect(offer.matches(batch: batch, limits: limits, at: t(1)), "exact offer can be accepted")
        expect(!offer.matches(batch: batch, limits: limits, at: t(5)), "expired offer rejected")
        expect(!offer.matches(batch: TrafficBatch(routeID: "other", checkedAt: date, samples: batch.samples), limits: limits, at: t(1)), "route identity")
        let changed = TrafficBatch(routeID: "route", checkedAt: t(1), samples: [early, option(15, 52)])
        expect(!offer.matches(batch: changed, limits: limits, at: t(1)), "no changing facts under consent")
        for packing in 0...30 {
            expect(DepartureCuePhase.resolve(now: date, departure: date, packing: Double(packing * 60)) == .leaveNow, "due cue \(packing)")
            expect(DepartureCuePhase.resolve(now: t(1), departure: date, packing: Double(packing * 60)) == .missed, "missed cue \(packing)")
        }
        // Review 2: interruption, immediate mode and layout changes cannot resurrect old glyphs.
        var morph = DotMorph()
        morph.move(to: [1, 0, 1], at: date, animated: false)
        expect(morph.values(at: date) == [1, 0, 1] && !morph.running, "first glyph is immediate")
        morph.move(to: [0, 1, 1], at: date, animated: true)
        let midpoint = date.addingTimeInterval(DotMorph.duration / 2)
        let visible = morph.values(at: midpoint)
        // A fully damped response is not halfway at half its tail budget.
        // The exact curve and velocity are checked independently in FluidityTests.
        expect(visible[0] > 0 && visible[0] < 1 && visible[2] == 1, "changed dots progress while unchanged dots stay fixed")
        morph.move(to: [1, 0, 0], at: midpoint, animated: true)
        expect(morph.values(at: midpoint) == visible, "retarget starts from the currently visible dots")
        expect(morph.values(at: midpoint.addingTimeInterval(1)) == [1, 0, 0], "retarget settles on the latest glyph")
        morph.finish()
        expect(!morph.running && morph.values(at: date) == [1, 0, 0], "reduce motion or closing stops the animation")
        morph.move(to: [0, 1], at: date, animated: true)
        expect(!morph.running && morph.values(at: date) == [0, 1], "different glyph layout updates immediately")
        morph.move(to: [1, 0], at: date, animated: false)
        expect(!morph.running && morph.values(at: date) == [1, 0], "nonanimated changes never display previous dots")
        var daylight = Calendar(identifier: .gregorian)
        daylight.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let transition = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!
        expect(JourneyDay.key(transition, calendar: daylight) == JourneyDay.key(transition.addingTimeInterval(22 * 3600), calendar: daylight), "spring clock change remains one local day")
        expect(JourneyDay.key(transition, calendar: daylight) != JourneyDay.key(transition.addingTimeInterval(23 * 3600), calendar: daylight), "spring day ends after 23 hours")

        for (input, output): (CGFloat, CGFloat) in [(1, 1), (1.2, 1.2), (1.4, 1.4), (0, 1), (-2, 1), (8, 1.4), (.infinity, 1), (.nan, 1)] {
            expect(WindowTextMetrics.normalized(input) == output, "reading-size bounds are safe")
        }
        expect(WindowTextMetrics.editorWidth(300, scale: 1.4) == 380, "editors grow with their text")
        for (input, output): (String, Int?) in [("17:30", 1050), ("17:10", 1030), (" 7:05 ", 425), ("07:05", 425), ("17.40", 1060),
                                                 ("1815", 1095), ("705", 425), ("0:00", 0), ("23:59", 1439),
                                                 ("24:00", nil), ("17:60", nil), ("17:5", nil), ("5:30 PM", nil), ("", nil),
                                                 ("17:30:00", nil), ("-1:30", nil), ("12345", nil), ("1:2:3", nil), ("ab:cd", nil)] {
            expect(MinuteEntry.clock(input) == output, "24-hour entry \(input)")
        }
        expect(MinuteEntry.clockText(1030) == "17:10" && MinuteEntry.clockText(425) == "07:05", "editors seed the 24-hour value")
        expect(MinuteEntry.clockText(-5) == "00:00" && MinuteEntry.clockText(2000) == "23:59", "clock text stays a real time")
        for minute in stride(from: 0, through: 1439, by: 7) {
            expect(MinuteEntry.clock(MinuteEntry.clockText(minute)) == minute, "clock text round-trips")
        }
        expect(WindowCopy.minutes(1) == "1 minute", "singular spoken duration")
        expect(WindowCopy.minutes(0) == "0 minutes", "zero duration")
        expect(WindowCopy.minutes(5) == "5 minutes", "plural duration")
        let oneMinute = option(0, 1)
        expect(WindowCopy.spokenDriving(oneMinute) == "About 1 minute driving", "speech is approximate and grammatical")
        expect(WindowCopy.travelLine(oneMinute).hasPrefix("About 1 min driving · Arrive around "), "visible estimate preserves uncertainty")
        expect(!WindowCopy.offerNeedsCheck.contains("has expired"), "invalid offers may have causes other than age")
        expect(WindowCopy.privacy.contains("route coordinates go to Apple Maps"), "privacy distinguishes local storage from route requests")

        print("PASS: \(checks) evening core checks")
    }
}
