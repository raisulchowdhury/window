import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

#if !WINDOW_CORE_TESTS
@main
#endif
struct CraftCoreTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    static func main() {
        runWatchCoreTests()
        func mapsError(_ code: Int) -> Error { NSError(domain: "MKErrorDomain", code: code) }
        expect(MapsErrorCopy.message(for: mapsError(4), request: .place) == "Couldn’t find that place.", "placemark not found reads plainly")
        expect(MapsErrorCopy.message(for: mapsError(5), request: .route) == "No route found.", "directions not found reads plainly")
        expect(MapsErrorCopy.message(for: mapsError(5), request: .place) == "No route found.", "directions error keeps its meaning")
        expect(MapsErrorCopy.message(for: mapsError(4), request: .route) == "No route found.", "a route with a missing end has no route")
        // Gemini claim 1: throttling is told apart (so the watch can back off) but reads the same.
        expect(MapsErrorCopy.isThrottled(mapsError(3)) && !MapsErrorCopy.isThrottled(mapsError(2))
               && !MapsErrorCopy.isThrottled(NSError(domain: "fixture", code: 3)), "only MapKit code 3 is throttling")
        expect(MapsThrottledError().localizedDescription == "Apple Maps isn’t responding. Try again.", "throttling still reads as not responding")
        for code in [1, 2, 3, 6, 99] {
            expect(MapsErrorCopy.message(for: mapsError(code), request: .place) == "Apple Maps isn’t responding. Try again.",
                   "MapKit code \(code) reads as not responding")
        }
        expect(MapsErrorCopy.message(for: NSError(domain: NSURLErrorDomain, code: -1001), request: .route) == MapsErrorCopy.notResponding,
               "network timeout reads as not responding")
        struct RawMapsError: LocalizedError { var errorDescription: String? { "The operation couldn’t be completed. (MKErrorDomain error 2.)" } }
        expect(MapsErrorCopy.message(for: RawMapsError(), request: .place) == MapsErrorCopy.notResponding,
               "raw error text never passes through")
        expect(MapsErrorCopy.message(for: nil, request: .place) == MapsErrorCopy.placeNotFound
               && MapsErrorCopy.message(for: nil, request: .route) == MapsErrorCopy.noRoute, "no response without an error")
        let departure = Date(timeIntervalSince1970: 1_800_000_000)
        func phase(_ offset: TimeInterval, packing: TimeInterval = 300, prepared: Bool = false) -> DepartureCuePhase {
            DepartureCuePhase.resolve(now: departure.addingTimeInterval(offset), departure: departure,
                                      packing: packing, preparationAlreadyUnderway: prepared)
        }
        expect(phase(-301) == .waiting, "before wrap-up")
        expect(phase(-300) == .wrappingUp, "wrap-up boundary")
        expect(phase(-1) == .wrappingUp, "one second before departure")
        expect(phase(0) == .leaveNow, "nonzero preparation must say leave at departure")
        expect(phase(59) == .leaveNow, "due-minute grace")
        expect(phase(60) == .missed, "existing missed boundary")
        expect(phase(-1, packing: 0) == .waiting, "zero preparation has no early wrap-up")
        expect(phase(0, packing: 0) == .leaveNow, "zero preparation at departure")
        expect(phase(-360, prepared: true) == .wrappingUp, "accepted recovery preserves preparation")
        expect(phase(0, prepared: true) == .leaveNow, "recovery advances to due")
        expect(phase(60, prepared: true) == .missed, "recovery cannot override missed state")

        // Every supported preparation duration respects the same due and missed boundaries.
        for minutes in 0...30 {
            let packing = TimeInterval(minutes * 60)
            expect(phase(-packing - 1, packing: packing) == .waiting, "waiting at \(minutes) min")
            expect(phase(-packing, packing: packing) == (minutes == 0 ? .leaveNow : .wrappingUp), "preparation boundary at \(minutes) min")
            expect(phase(0, packing: packing) == .leaveNow, "due at \(minutes) min")
            expect(phase(59, packing: packing) == .leaveNow, "grace at \(minutes) min")
            expect(phase(60, packing: packing) == .missed, "missed at \(minutes) min")
        }

        // Guard shared planning invariants. The evening default has separate coverage.
        let limits = WatchLimits(earliest: departure, latest: departure.addingTimeInterval(3600),
                                 homeBy: departure.addingTimeInterval(10800), packing: 300)
        let early = DepartureEstimate(departure: departure, driving: 78 * 60)
        let later = DepartureEstimate(departure: departure.addingTimeInterval(30 * 60), driving: 70 * 60)
        expect(DeparturePolicy.earliestArrival([early, later]) == early, "earliest-arrival helper remains available")
        expect(DeparturePolicy.lessDrivingAlternative([early, later], comparedWith: early) == later, "checked less-driving alternative")
        expect(DepartureTradeoff(later, comparedWith: early).text == "Wait 30 min · drive 8 min less · arrive 22 min later", "full waiting cost")
        expect(DeparturePolicy.recommend([early, later], limits: limits, now: departure.addingTimeInterval(-600), committed: later.departure) == later, "feasible commitment stays stable")
        let batch = TrafficBatch(routeID: "fixture", checkedAt: departure, samples: [early])
        expect(batch.isFresh(at: departure.addingTimeInterval(299)), "fresh before five minutes")
        expect(!batch.isFresh(at: departure.addingTimeInterval(300)), "expired at five minutes")
        let exactDelay = departure.addingTimeInterval(300)
        expect(DeparturePolicy.candidates(now: departure.addingTimeInterval(1), limits: limits, committed: departure, requested: exactDelay).contains(exactDelay), "explicit exact delay remains sampled after departure")
        let original = WatchLimits(earliest: departure, latest: departure.addingTimeInterval(600),
                                   homeBy: departure.addingTimeInterval(3600), packing: 300)
        let late = DepartureEstimate(departure: departure, driving: 70 * 60)
        let exception = RecoveryPolicy.acceptedLimits(for: late, original: original)
        expect(exception.fits(late), "explicit recovery fits accepted limits")
        expect(original.homeBy == departure.addingTimeInterval(3600), "original limits remain unchanged")
        var gate = WatchRequestGate(); gate.begin()
        let session = gate.session!, revision = gate.next()
        gate.stop(); gate.begin()
        expect(!gate.accepts(revision, session: session), "old-session completion rejected")
        print("PASS: \(checks) portable craft/core assertions. No native UI or notification delivery tested.")
    }
}
