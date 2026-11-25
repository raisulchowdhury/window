import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

func runWatchCoreTests() {
    let day = Date(timeIntervalSince1970: 1_789_000_000)
    func t(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    let limits = WatchLimits(earliest: t(10), latest: t(40), homeBy: t(75), packing: 5 * 60)
    let samples = [DepartureEstimate(departure: t(10), driving: 55 * 60), DepartureEstimate(departure: t(30), driving: 30 * 60), DepartureEstimate(departure: t(35), driving: 30 * 60)]
    assert(DeparturePolicy.recommend(samples, limits: limits, now: t(5), committed: nil)?.departure == t(30))
    for minute in 25...30 { assert(DeparturePolicy.recommend(samples, limits: limits, now: t(Double(minute)), committed: t(30))?.departure == t(30)) }
    let worsened = [DepartureEstimate(departure: t(30), driving: 62 * 60)]
    assert(DeparturePolicy.recommend(worsened, limits: limits, now: t(25), committed: t(30)) == nil)
    assert(DeparturePolicy.recommend([], limits: limits, now: t(5), committed: nil) == nil) // never turn missing evidence into a simulated route
    let baseline = samples[0]
    let batch = TrafficBatch(routeID: "route", checkedAt: t(5), samples: samples)
    assert(batch.isFresh(at: t(9))); assert(!batch.isFresh(at: t(10)))
    assert(batch.sample(at: t(31)) == nil) // no interpolation
    let changedBatch = TrafficBatch(routeID: "route", checkedAt: t(10), samples: [DepartureEstimate(departure: t(10), driving: 50 * 60)])
    assert(baseline.driving == 55 * 60 && changedBatch.samples[0].driving == 50 * 60)
    let slots = DeparturePolicy.candidates(now: t(5), limits: limits, committed: t(30), requested: t(35))
    assert(slots.contains(t(30)) && slots.contains(t(35)) && slots.count <= 12)
    assert(slots.allSatisfy { $0 >= t(5) && $0 <= limits.latest })
    var gate = WatchRequestGate(); gate.begin(); let session = gate.session!; let old = gate.next(); let current = gate.next()
    assert(!gate.accepts(old, session: session)); assert(gate.accepts(current, session: session)); gate.stop(); assert(!gate.accepts(current, session: session))
    gate.begin(); assert(!gate.accepts(current, session: session))
    assert(limits.validation(at: t(50)) != nil)
    let suite = "window-tests-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
    let store = JourneyStore(defaults: defaults); var saved = SavedJourney(); saved.packing = 15; store.save(saved); assert(store.load().packing == 15)
    saved.packing = -1; store.save(saved); assert(store.load().packing == 15)
    let recoveryNow = DeparturePolicy.roundedMinute(t(0))
    func r(_ minute: Double) -> Date { recoveryNow.addingTimeInterval(minute * 60) }
    let tight = WatchLimits(earliest: r(5), latest: r(35), homeBy: r(50), packing: 300)
    let lateChoices = [DepartureEstimate(departure: r(5), driving: 3600),
                       DepartureEstimate(departure: r(25), driving: 2700),
                       DepartureEstimate(departure: r(30), driving: 3000)]
    let choices = RecoveryPolicy.options(lateChoices, limits: tight, now: r(0))!
    assert(choices.primary == lateChoices[0] && choices.alternative == lateChoices[1])
    assert(RecoveryPolicy.options([DepartureEstimate(departure: r(4), driving: 1800)], limits: tight, now: r(0)) == nil)
    assert(RecoveryPolicy.options([DepartureEstimate(departure: r(5), driving: .nan)], limits: tight, now: r(0)) == nil)
    let lateLimits = RecoveryPolicy.acceptedLimits(for: choices.primary, original: tight)
    assert(lateLimits.homeBy == r(75) && lateLimits.buffer == 600 && lateLimits.fits(choices.primary))
    let onTime = DepartureEstimate(departure: r(5), driving: 40 * 60)
    let lessBuffer = RecoveryPolicy.acceptedLimits(for: onTime, original: tight)
    assert(lessBuffer.homeBy == tight.homeBy && lessBuffer.buffer == 300 && lessBuffer.fits(onTime))
    let noBuffer = RecoveryPolicy.acceptedLimits(for: DepartureEstimate(departure: r(5), driving: 45 * 60), original: tight)
    assert(noBuffer.buffer == 0 && noBuffer.homeBy == tight.homeBy)
    let outside = DepartureEstimate(departure: r(40), driving: 30 * 60)
    assert(RecoveryPolicy.acceptedLimits(for: outside, original: tight).latest == r(40))
    let slightSaving = [lateChoices[0], DepartureEstimate(departure: r(25), driving: 55 * 60)]
    assert(RecoveryPolicy.options(slightSaving, limits: tight, now: r(0))?.alternative == nil)
    let broad = WatchLimits(earliest: r(5), latest: r(60), homeBy: r(180), packing: 300)
    let costlyWait = [DepartureEstimate(departure: r(5), driving: 78 * 60), DepartureEstimate(departure: r(35), driving: 70 * 60)]
    assert(DeparturePolicy.recommend(costlyWait, limits: broad, now: r(0), committed: nil) == costlyWait[1])
    let tradeoff = DepartureTradeoff(costlyWait[1], comparedWith: costlyWait[0])
    assert(tradeoff.waitMinutes == 30 && tradeoff.drivingMinutesSaved == 8 && tradeoff.arrivalMinutesLater == 22)
    assert(tradeoff.text == "Wait 30 min · drive 8 min less · arrive 22 min later")
    assert(DeparturePolicy.recommend(costlyWait, limits: broad, now: r(0), committed: costlyWait[1].departure) == costlyWait[1])
    let worthwhile = [DepartureEstimate(departure: r(5), driving: 60 * 60), DepartureEstimate(departure: r(10), driving: 50 * 60)]
    assert(DeparturePolicy.recommend(worthwhile, limits: broad, now: r(0), committed: nil) == worthwhile[1])
    assert(DepartureTradeoff(worthwhile[1], comparedWith: worthwhile[0]).arrivalMinutesLater == -5)
    let tied = [DepartureEstimate(departure: r(5), driving: 60 * 60), DepartureEstimate(departure: r(15), driving: 50 * 60)]
    assert(DeparturePolicy.recommend(tied, limits: broad, now: r(0), committed: nil) == tied[1])
    let midnight = Calendar.current.startOfDay(for: recoveryNow).addingTimeInterval(24 * 3600)
    let beforeMidnight = midnight.addingTimeInterval(-6 * 60)
    let overnight = WatchLimits(earliest: beforeMidnight, latest: midnight.addingTimeInterval(-5 * 60), homeBy: midnight.addingTimeInterval(-60), packing: 600)
    assert(RecoveryPolicy.options([DepartureEstimate(departure: midnight.addingTimeInterval(240), driving: 1800)], limits: overnight, now: beforeMidnight) == nil)
    print("PASS: live policy, minute-by-minute commitment, traffic risk, missing evidence, expiry, exact samples, frozen baseline, bounded candidates, late-response rejection, persistence")
}
