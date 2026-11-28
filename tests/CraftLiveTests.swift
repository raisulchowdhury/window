import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

@MainActor final class CraftTraffic: TrafficProviding {
    var duration: (Date) -> TimeInterval = { _ in 1800 }
    var blocked = false
    var failing = false
    var requests: [Date] = []
    var waiting: [(Date, CheckedContinuation<DepartureEstimate, Error>)] = []
    struct Failure: Error {}
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        requests.append(departing)
        if failing { throw Failure() }
        if blocked { return try await withCheckedThrowingContinuation { waiting.append((departing, $0)) } }
        return DepartureEstimate(departure: departing, driving: duration(departing))
    }
    func releaseFirst(_ count: Int) {
        let pending = Array(waiting.prefix(count)); waiting.removeFirst(pending.count)
        for (date, continuation) in pending {
            continuation.resume(returning: DepartureEstimate(departure: date, driving: duration(date)))
        }
    }
    func releaseAll() { blocked = false; releaseFirst(waiting.count) }
}

@MainActor final class CraftAlerts: WatchAlerting {
    var state: AlertAuthorization = .allowed
    var submissions: [(id: String, title: String)] = []
    var removed: [String] = []
    func authorization(request: Bool) async -> AlertAuthorization { state }
    func deliver(id: String, title: String, body: String) async throws { submissions.append((id, title)) }
    func remove(ids: [String]) { removed += ids }
}

@MainActor final class CraftFixture {
    let day = Calendar.current.startOfDay(for: Date())
    var date: Date
    let suite = "window-craft-tests-\(UUID().uuidString)"
    let traffic = CraftTraffic()
    let alerts = CraftAlerts()
    var watch: LiveWatch!
    init() {
        date = Calendar.current.date(bySettingHour: 17, minute: 5, second: 0, of: day)!
        let defaults = UserDefaults(suiteName: suite)!
        watch = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: alerts,
                          clock: { [weak self] in self?.date ?? .distantPast })
        var saved = SavedJourney()
        saved.origin = SavedPlace(name: "Office", address: "Test origin", latitude: 37, longitude: -122)
        saved.destination = SavedPlace(name: "Home", address: "Test destination", latitude: 38, longitude: -122)
        watch.settings = saved
        let threshold = at(1050)
        traffic.duration = { $0 < threshold ? 55 * 60 : 30 * 60 }
    }
    func at(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)!
    }
    func advance(_ minute: Int, seconds: TimeInterval = 0) { date = at(minute).addingTimeInterval(seconds); watch.tick() }
    func clean() { watch.shutdown(); traffic.releaseAll(); UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
}

#if !WINDOW_CORE_TESTS
@main
#endif
struct CraftLiveTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        print("FAIL: asynchronous test did not settle"); exit(1)
    }
    @MainActor static func start(_ fixture: CraftFixture) async {
        fixture.watch.begin()
        await until { !fixture.watch.checking && fixture.watch.alertAuthorization != .unknown }
        if let offer = fixture.watch.proposal { expect(fixture.watch.acceptOffer(offer), "explicit fixture acceptance") }
        expect(fixture.watch.plan?.departure == fixture.at(1050), "known initial departure")
    }
    @MainActor static func main() async {
        // These tests compile the actual LiveWatch and WatchCore with fake services.
        // They do not activate the runtime monitor, call Maps or request OS notification permission.
        let cue = CraftFixture(); defer { cue.clean() }
        await start(cue)
        expect(cue.watch.cuePhase == .waiting, "initial phase")
        cue.advance(1045); await until { !cue.watch.checking && cue.watch.cueSubmitted }
        expect(cue.watch.departureCue == "Wrap up now", "preparation cue")
        expect(cue.watch.menuTitle == " Wrap up", "preparation menu")
        expect(cue.alerts.submissions.count == 1, "one preparation submission")
        cue.advance(1050); await until { !cue.watch.checking && cue.alerts.submissions.count >= 2 }
        expect(cue.watch.departureCue == "Leave now", "nonzero preparation due cue")
        expect(cue.watch.menuTitle == " Leave now", "nonzero preparation due menu")
        expect(cue.alerts.submissions.map { $0.title } == ["Time to wrap up", "Time to leave"],
               "two cues per departure: wrap up, then leave at departure")
        cue.advance(1050, seconds: 59)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(cue.watch.departureCue == "Leave now", "due-minute grace wording")
        expect(cue.alerts.submissions.count == 2, "the leave cue never fires twice")
        cue.advance(1051)
        expect(cue.watch.missed && cue.watch.menuTitle == " Check plan", "missed state takes priority")
        expect(cue.watch.departureCue == "Departure time passed", "missed cue is not actionable")

        let zero = CraftFixture(); defer { zero.clean() }
        zero.watch.settings.packing = 0
        await start(zero)
        expect(zero.watch.departureCue == "No wrap-up needed", "zero preparation before due")
        zero.advance(1050); await until { !zero.watch.checking && zero.watch.cueSubmitted }
        expect(zero.watch.departureCue == "Leave now" && zero.watch.menuTitle == " Leave now", "zero preparation due")
        expect(zero.alerts.submissions.last?.title == "Time to leave", "zero preparation alert title")

        let enabledAtDue = CraftFixture(); defer { enabledAtDue.clean() }
        enabledAtDue.alerts.state = .denied
        await start(enabledAtDue)
        enabledAtDue.advance(1045); await until { !enabledAtDue.watch.checking }
        expect(enabledAtDue.alerts.submissions.isEmpty, "denied means no cue")
        enabledAtDue.alerts.state = .allowed
        enabledAtDue.advance(1050)
        enabledAtDue.watch.updateAuthorization(request: false)
        await until { !enabledAtDue.watch.checking && enabledAtDue.watch.cueSubmitted }
        expect(enabledAtDue.alerts.submissions.count == 1, "first cue at due")
        expect(enabledAtDue.alerts.submissions.last?.title == "Time to leave", "late first cue uses due phase")

        let delay = CraftFixture(); defer { delay.clean() }
        await start(delay)
        delay.advance(1049); await until { !delay.watch.checking }
        let originalLimits = delay.watch.limits
        delay.traffic.blocked = true
        delay.date = delay.at(1050).addingTimeInterval(1) // No tick: the action must read the current clock.
        delay.watch.delay()
        expect(delay.watch.checking, "enabled delay starts just after departure")
        expect(delay.watch.pendingDeparture == delay.at(1055), "exact pending five-minute delay")
        expect(delay.watch.plan?.departure == delay.at(1050), "pending is not confirmed")
        expect(delay.watch.status == "Checking \(liveTime(delay.at(1055)))…", "specific pending feedback")
        expect(delay.watch.menuTitle == " Leave now", "pending request does not replace current due instruction")
        delay.watch.delay()
        expect(delay.watch.pendingDeparture == delay.at(1055), "repeated click does not stack delays")
        await until { !delay.traffic.waiting.isEmpty }
        delay.traffic.releaseAll(); await until { !delay.watch.checking }
        expect(delay.watch.plan?.departure == delay.at(1055), "fresh requested departure accepted")
        expect(delay.watch.pendingDeparture == nil, "pending cleared on success")
        expect(delay.watch.limits == originalLimits, "delay preserves all limits")
        expect(delay.watch.planNotice == "Departure set to \(liveTime(delay.at(1055))).", "result names accepted departure")

        let missed = CraftFixture(); defer { missed.clean() }
        await start(missed)
        missed.advance(1049); await until { !missed.watch.checking }
        let requestsBefore = missed.traffic.requests.count
        missed.date = missed.at(1051) // A stale button cannot bypass the missed threshold.
        missed.watch.delay()
        expect(missed.watch.missed && !missed.watch.checking, "no new delay after missed threshold")
        expect(missed.traffic.requests.count == requestsBefore, "missed action does not query")
        expect(missed.watch.pendingDeparture == nil, "missed action has no pending state")

        let offline = CraftFixture(); defer { offline.clean() }
        await start(offline)
        offline.traffic.blocked = true; offline.watch.delay()
        await until { !offline.traffic.waiting.isEmpty }
        offline.watch.connectivityChanged(false)
        expect(offline.watch.pendingDeparture == nil && !offline.watch.checking, "offline clears pending state")
        expect(offline.watch.status == "Paused · no connection", "offline outranks pending")
        offline.traffic.releaseAll(); try? await Task.sleep(nanoseconds: 20_000_000)
        expect(offline.watch.plan?.departure == offline.at(1050) && offline.watch.stale, "late offline result cannot confirm delay")

        let failure = CraftFixture(); defer { failure.clean() }
        await start(failure)
        failure.traffic.failing = true; failure.watch.delay()
        await until { !failure.watch.checking }
        expect(failure.watch.pendingDeparture == nil && failure.watch.stale, "failure clears pending and unconfirms evidence")
        expect(failure.watch.plan?.departure == failure.at(1050), "failed delay retains previous information")

        let sessions = CraftFixture(); defer { sessions.clean() }
        await start(sessions)
        sessions.traffic.blocked = true; sessions.watch.delay()
        await until { sessions.traffic.waiting.count >= 2 }
        let oldWaiting = sessions.traffic.waiting.count
        sessions.watch.finish(title: "Stopped", message: "")
        expect(sessions.watch.pendingDeparture == nil, "stop clears pending")
        sessions.traffic.blocked = false
        await start(sessions) // Original cancelled continuations remain held by the fake provider.
        sessions.traffic.blocked = true; sessions.watch.delay()
        await until { sessions.traffic.waiting.count >= oldWaiting + 2 }
        sessions.traffic.releaseFirst(oldWaiting)
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(sessions.watch.checking && sessions.watch.pendingDeparture == sessions.at(1055), "old completion cannot clear newer pending action")
        sessions.traffic.releaseAll(); await until { !sessions.watch.checking }
        expect(sessions.watch.plan?.departure == sessions.at(1055) && sessions.watch.pendingDeparture == nil, "new session owns its result")

        print("PASS: \(checks) craft controller assertions with fake services. Native UI and real notification presentation are separate acceptance checks.")
    }
}
