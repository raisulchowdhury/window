import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

@MainActor final class InteractionTraffic: TrafficProviding {
    var requests = 0
    var blocked = false
    var waiting: [(Date, CheckedContinuation<DepartureEstimate, Error>)] = []
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        requests += 1
        if blocked { return try await withCheckedThrowingContinuation { waiting.append((departing, $0)) } }
        return DepartureEstimate(departure: departing, driving: 1800)
    }
    func release() {
        blocked = false
        let held = waiting; waiting = []
        for (date, continuation) in held { continuation.resume(returning: DepartureEstimate(departure: date, driving: 1800)) }
    }
}
@MainActor final class InteractionAlerts: WatchAlerting {
    var state: AlertAuthorization = .allowed
    var authorizationCalls = 0
    var holdAuthorization = true
    var waiting: [CheckedContinuation<AlertAuthorization, Never>] = []
    var submissions: [String] = []
    var holdDelivery = false
    var failDelivery = false
    var deliveryWaiting: [CheckedContinuation<Void, Never>] = []
    var removed: [String] = []
    func authorization(request: Bool) async -> AlertAuthorization {
        authorizationCalls += 1
        if holdAuthorization { return await withCheckedContinuation { waiting.append($0) } }
        return state
    }
    func deliver(id: String, title: String, body: String) async throws {
        if failDelivery { throw NSError(domain: "interaction-test", code: 1) }
        if holdDelivery { await withCheckedContinuation { deliveryWaiting.append($0) } }
        submissions.append(id)
    }
    func remove(ids: [String]) { removed += ids; submissions.removeAll { ids.contains($0) } }
    func releaseDelivery() {
        holdDelivery = false
        let held = deliveryWaiting; deliveryWaiting = []
        for continuation in held { continuation.resume() }
    }
    func releaseFirst() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: state)
    }
    func release() {
        holdAuthorization = false
        let held = waiting; waiting = []
        for continuation in held { continuation.resume(returning: state) }
    }
}
#if !WINDOW_CORE_TESTS
@main
#endif
struct MicroInteractionTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Async fixture did not settle")
    }
    @MainActor static func main() async {
        let suite = "window-interactions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let traffic = InteractionTraffic(), alerts = InteractionAlerts()
        let watch = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: alerts)
        defer { alerts.release(); traffic.release(); watch.shutdown() }
        let first = Task { await watch.testAlert() }
        await until { alerts.waiting.count == 1 }
        let repeated = Task { await watch.testAlert() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(alerts.authorizationCalls == 1, "a second surface must not start a second permission/test request")
        alerts.release()
        _ = await first.value; _ = await repeated.value
        expect(alerts.submissions.count == 1, "one explicit test gesture produces one alert")
        // Review 2: an explicit permission request queued behind a passive read
        // must stay single-flight when a test alert is requested concurrently.
        let queuedAlerts = InteractionAlerts()
        let queued = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: queuedAlerts)
        defer { queuedAlerts.release(); queued.shutdown() }
        queued.updateAuthorization(request: false)
        await until { queuedAlerts.waiting.count == 1 }
        let testing = Task { await queued.testAlert() }
        queued.updateAuthorization(request: true)
        queuedAlerts.releaseFirst()
        await until { queuedAlerts.authorizationCalls >= 2 }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(queuedAlerts.authorizationCalls == 2, "queued permission and a test share the explicit authorization request")
        expect(queuedAlerts.waiting.count == 1, "at most one permission operation is waiting")
        queuedAlerts.release(); _ = await testing.value
        expect(queuedAlerts.submissions.count == 1, "shared permission completes one test")
        let lateAlerts = InteractionAlerts(); lateAlerts.holdAuthorization = false; lateAlerts.holdDelivery = true
        let late = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: lateAlerts)
        let lateTest = Task { await late.testAlert() }
        await until { !lateAlerts.deliveryWaiting.isEmpty }
        late.shutdown(); lateAlerts.releaseDelivery(); _ = await lateTest.value
        expect(lateAlerts.submissions.isEmpty, "shutdown removes a late completed test alert")
        expect(!late.testingAlert && !late.requestingAlertPermission, "shutdown clears shared progress")
        let oldRequests = lateAlerts.authorizationCalls
        _ = await late.testAlert(); late.updateAuthorization(request: true)
        expect(lateAlerts.authorizationCalls == oldRequests, "shut down controller cannot request permission again")

        let waitingAlerts = InteractionAlerts()
        let waitingWatch = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: waitingAlerts)
        let waitingTest = Task { await waitingWatch.testAlert() }
        await until { !waitingAlerts.waiting.isEmpty }
        waitingWatch.shutdown(); waitingAlerts.release(); _ = await waitingTest.value
        expect(waitingAlerts.submissions.isEmpty, "shutdown during permission cannot post a test")

        let deniedAlerts = InteractionAlerts(); deniedAlerts.holdAuthorization = false; deniedAlerts.state = .denied
        let deniedWatch = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: deniedAlerts)
        defer { deniedWatch.shutdown() }
        _ = await deniedWatch.testAlert()
        expect(deniedAlerts.submissions.isEmpty && !deniedWatch.testingAlert, "denied test completes without delivery")
        expect(!deniedWatch.testAlertMessage.isEmpty, "denial has shared feedback")
        deniedAlerts.state = .allowed; deniedAlerts.failDelivery = true
        _ = await deniedWatch.testAlert()
        expect(deniedWatch.testAlertMessage.contains("rejected") && !deniedWatch.testingAlert, "failed test has feedback and permits retry")
        deniedAlerts.failDelivery = false
        _ = await deniedWatch.testAlert()
        expect(deniedAlerts.submissions.count == 1 && deniedWatch.testAlertMessage.contains("submitted"), "retry names submission, not observed presentation")

        var clock = Calendar.current.date(bySettingHour: 17, minute: 5, second: 0, of: Date())!
        let retryAlerts = InteractionAlerts(); retryAlerts.holdAuthorization = false; retryAlerts.state = .denied
        let retryTraffic = InteractionTraffic()
        let retry = LiveWatch(store: JourneyStore(defaults: defaults), provider: retryTraffic, alerts: retryAlerts, clock: { clock })
        defer { retryTraffic.release(); retry.shutdown() }
        var journey = SavedJourney()
        journey.origin = SavedPlace(name: "Office", address: "Fixture", latitude: 37, longitude: -122)
        journey.destination = SavedPlace(name: "Home", address: "Fixture", latitude: 38, longitude: -122)
        retry.settings = journey
        expect(!retry.canRecheck && !retry.recheck(), "idle retry does not start an unauthorized watch")
        retry.begin(); await until { !retry.checking }
        expect(retry.acceptOffer(retry.proposal!), "explicitly accept fixture")
        let committed = retry.plan, limits = retry.limits
        retryTraffic.blocked = true
        expect(retry.recheck(), "first retry starts a check")
        await until { !retryTraffic.waiting.isEmpty }
        let requests = retryTraffic.requests
        expect(!retry.recheck(replan: true), "repeated retry cannot erase a plan or supersede pending work")
        expect(retryTraffic.requests == requests && retry.plan == committed && retry.limits == limits, "pending retry retains evidence and limits")
        retryTraffic.release(); await until { !retry.checking }
        retry.connectivityChanged(false)
        expect(!retry.recheck() && retry.delayUnavailableReason != nil, "offline action is disabled with explanation")
        clock = clock.addingTimeInterval(26 * 60)
        retry.tick()
        expect(retry.delayUnavailableReason != nil, "passed departure keeps an explanation")
        retry.connectivityChanged(true)
        if retry.checking { await until { !retry.checking } }
        expect(retry.recheck(replan: true), "explicit passed-time retry starts new checked evidence")
        await until { !retry.checking }

        let permissionAlerts = InteractionAlerts(); permissionAlerts.holdAuthorization = false; permissionAlerts.failDelivery = true
        let permissionNow = Calendar.current.date(bySettingHour: 17, minute: 5, second: 0, of: Date())!
        let permissionWatch = LiveWatch(store: JourneyStore(defaults: defaults), provider: InteractionTraffic(), alerts: permissionAlerts, clock: { permissionNow })
        defer { permissionWatch.shutdown() }
        permissionWatch.settings = journey
        permissionWatch.begin(); await until { !permissionWatch.checking }
        expect(permissionWatch.acceptOffer(permissionWatch.proposal!), "accept immediate wrap-up fixture")
        await until { permissionWatch.alertError != nil && !permissionWatch.requestingAlertPermission }
        let deliveryError = permissionWatch.alertError
        permissionAlerts.failDelivery = false
        permissionWatch.updateAuthorization(request: false)
        await until { !permissionWatch.requestingAlertPermission }
        expect(permissionWatch.alertError == deliveryError, "permission refresh cannot erase an unresolved watch-delivery failure")

        let edit = JourneyEdit(day: "today", revision: 4, value: journey)
        expect(edit.acceptsChild(edit.id, day: "today", revision: 4), "matching child owns its parent draft")
        expect(!edit.acceptsChild(UUID(), day: "today", revision: 4), "replacement draft rejects old child")
        expect(!edit.acceptsChild(nil, day: "today", revision: 4), "cancelled parent rejects child")
        expect(!edit.acceptsChild(edit.id, day: "tomorrow", revision: 4), "midnight invalidates nested edits")
        expect(!edit.acceptsChild(edit.id, day: "today", revision: 5), "another window invalidates nested edits")
        for minute in 0...30 { expect(MinuteEntry.value("\(minute)") == minute, "exact minute \(minute)") }
        for invalid in ["", " ", "-1", "31", "1.5", "abc", "999999999999999999999999999999"] {
            expect(MinuteEntry.value(invalid) == nil, "reject invalid minute text")
        }
        expect(MinuteEntry.value(" 7 \n") == 7, "trim harmless whitespace")
        expect(ResultSelection.moved(nil, in: [], direction: 1) == nil, "no invented search result")
        expect(ResultSelection.moved(nil, in: ["a", "b"], direction: 1) == "a", "down begins with first result")
        expect(ResultSelection.moved(nil, in: ["a", "b"], direction: -1) == "b", "up begins with last result")
        expect(ResultSelection.moved("b", in: ["a", "b"], direction: 1) == "b", "selection stops at bottom")
        expect(ResultSelection.moved("a", in: ["a", "b"], direction: -1) == "a", "selection stops at top")
        expect(ResultSelection.moved("old", in: ["new"], direction: 1) == "new", "selection belongs to current results")

        var scroll = ScrollEditSession()
        expect(scroll.handle(.changed, inside: true, enabled: true, vertical: true) == .passThrough, "page gesture begun elsewhere cannot edit")
        expect(scroll.handle(.began, inside: true, enabled: true, vertical: false) == .passThrough, "horizontal gesture belongs to page")
        expect(scroll.handle(.changed, inside: true, enabled: true, vertical: true) == .passThrough, "direction change cannot steal page ownership")
        expect(scroll.handle(.began, inside: true, enabled: true, vertical: false, stationary: true) == .consume, "zero-delta begin defers direction choice")
        expect(scroll.handle(.changed, inside: true, enabled: true, vertical: true) == .adjust, "deferred vertical gesture can adjust")
        expect(scroll.handle(.ended, inside: true, enabled: true, vertical: false) == .consume, "owned end does not scroll page")
        expect(scroll.handle(.momentum, inside: true, enabled: true, vertical: true) == .consume, "inertia never adjusts value")
        expect(scroll.handle(.changed, inside: true, enabled: true, vertical: true) == .passThrough, "ended gesture cannot start another edit")
        expect(scroll.handle(.began, inside: true, enabled: false, vertical: true) == .passThrough, "disabled input cannot be edited by scroll")
        expect(scroll.handle(.began, inside: true, enabled: true, vertical: true) == .adjust, "vertical begin owns value")
        expect(scroll.handle(.changed, inside: false, enabled: true, vertical: true) == .passThrough, "leaving value releases gesture")
        expect(scroll.handle(.changed, inside: true, enabled: true, vertical: true) == .passThrough, "reentering cannot reclaim gesture")
        expect(scroll.handle(.discrete, inside: true, enabled: true, vertical: true) == .adjust, "wheel notch remains supported")
        expect(scroll.handle(.began, inside: true, enabled: true, vertical: true) == .adjust, "new physical gesture can start")
        expect(scroll.handle(.cancelled, inside: true, enabled: true, vertical: false) == .consume, "cancelled owned gesture is finished")
        expect(scroll.handle(.momentum, inside: true, enabled: true, vertical: true) == .passThrough, "cancelled gesture cannot swallow later page inertia")
        var accumulator = TimeScrollAccumulator()
        expect(accumulator.steps(delta: .nan, precise: true, timestamp: 1) == 0, "nonfinite input cannot trap")
        expect(accumulator.steps(delta: .infinity, precise: true, timestamp: 2) == 0, "infinite input ignored")
        expect(accumulator.steps(delta: 12, precise: true, timestamp: .infinity) == 0, "invalid timestamp ignored")
        expect(accumulator.steps(delta: CGFloat.greatestFiniteMagnitude, precise: true, timestamp: 3) == 1000, "large finite event is bounded")
        expect(TimeScrollAccumulator.adjusted(5, steps: Int.max, bounds: 0...30) == 30, "positive multiply overflow clamps")
        expect(TimeScrollAccumulator.adjusted(5, steps: Int.min, bounds: 0...30) == 0, "negative multiply overflow clamps")
        expect(TimeScrollAccumulator.adjusted(Int.max, steps: 1, bounds: 0...Int.max) == Int.max, "positive sum overflow clamps")
        expect(TimeScrollAccumulator.adjusted(Int.min, steps: -1, bounds: Int.min...0) == Int.min, "negative sum overflow clamps")
        expect(JourneyPresentation.screen(model: "watch", editing: true) == "setup", "main-window edit does not mutate shared navigation")
        expect(JourneyPresentation.screen(model: "watch", editing: false) == "watch", "menu can keep showing the watch during a main-window edit")
        expect(JourneyPresentation.screen(model: "finished", editing: true) == "finished", "ending clears authority even during an edit")
        expect(JourneyPresentation.screen(model: "home", editing: false) == "home", "idle surface stays idle")
        #if WINDOW_CORE_TESTS
        // The wrap-up stepper lands on multiples of five (WindowPresentation.swift; Xcode build only).
        let wrapUp = 0...30
        for (typed, up, down) in [(7, 10, 5), (10, 15, 5), (0, 5, 0), (30, 30, 25), (29, 30, 25), (1, 5, 0), (28, 30, 25)] {
            expect(WindowStepperField.gridStep(typed, steps: 1, bounds: wrapUp) == up, "\(typed) steps up to \(up)")
            expect(WindowStepperField.gridStep(typed, steps: -1, bounds: wrapUp) == down, "\(typed) steps down to \(down)")
        }
        expect(WindowStepperField.gridStep(7, steps: 2, bounds: wrapUp) == 15 && WindowStepperField.gridStep(7, steps: -2, bounds: wrapUp) == 0,
               "further steps move by five from the first landing")
        expect(WindowStepperField.gridStep(7, steps: Int.max, bounds: wrapUp) == 30 && WindowStepperField.gridStep(7, steps: Int.min, bounds: wrapUp) == 0,
               "snapped steps clamp at the bounds without overflow")
        expect(WindowStepperField.gridStep(7, steps: 0, bounds: wrapUp) == 7, "no step leaves a typed value as typed")
        expect(WindowStepperField.stepped(7, steps: 1, bounds: 0...1439, snapsToFive: false) == 12, "time fields keep stepping by five from where they are")
        #endif
        print("PASS: \(checks) micro-interaction checks")
    }
}
