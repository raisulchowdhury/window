import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

#if !WINDOW_PORTABLE_TESTS && !WINDOW_CORE_TESTS
import AppKit
import SwiftUI
#endif
#if !WINDOW_PORTABLE_TESTS
import Combine
#endif

@MainActor final class TestTraffic: TrafficProviding {
    var seconds: (Date) -> TimeInterval = { _ in 1800 }
    var blocked = false
    var fails: (Date) -> Bool = { _ in false }
    var throttles: (Date) -> Bool = { _ in false }
    var requests = 0
    var waiting: [(Date, CheckedContinuation<DepartureEstimate, Error>)] = []
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        requests += 1
        if fails(departing) { throw CocoaError(.fileReadUnknown) }
        if throttles(departing) { throw MapsThrottledError() }
        if blocked { return try await withCheckedThrowingContinuation { waiting.append((departing, $0)) } }
        return DepartureEstimate(departure: departing, driving: seconds(departing))
    }
    func release() { let values = waiting; waiting = []; blocked = false; for (date, continuation) in values { continuation.resume(returning: DepartureEstimate(departure: date, driving: seconds(date))) } }
}
@MainActor final class TestAlerts: WatchAlerting {
    var state: AlertAuthorization = .allowed
    var posted: [String] = []
    var titles: [String] = []
    var removed: [String] = []
    var delayed = false
    var failuresRemaining = 0
    var delayAuthorization = false
    var authorizationCalls: [Bool] = []
    var authorizationWaiting: CheckedContinuation<AlertAuthorization, Never>?
    var waiting: CheckedContinuation<Void, Error>?
    func authorization(request: Bool) async -> AlertAuthorization {
        authorizationCalls.append(request)
        if delayAuthorization { return await withCheckedContinuation { authorizationWaiting = $0 } }
        return state
    }
    func releaseAuthorization() { delayAuthorization = false; authorizationWaiting?.resume(returning: state); authorizationWaiting = nil }
    func deliver(id: String, title: String, body: String) async throws {
        if delayed { try await withCheckedThrowingContinuation { waiting = $0 } }
        if failuresRemaining > 0 { failuresRemaining -= 1; throw CocoaError(.fileWriteUnknown) }
        posted.append(id); titles.append(title)
    }
    func release() { waiting?.resume(); waiting = nil; delayed = false }
    func remove(ids: [String]) { removed += ids; posted.removeAll { ids.contains($0) } }
}
@MainActor final class LiveFixture {
    let day: Date
    var date: Date
    let suite = "window-live-tests-\(UUID().uuidString)"
    let traffic = TestTraffic()
    let alerts = TestAlerts()
    var watch: LiveWatch!
    init() {
        day = Calendar.current.startOfDay(for: Date()); date = day.addingTimeInterval(17 * 3600 + 5 * 60)
        let defaults = UserDefaults(suiteName: suite)!
        watch = LiveWatch(store: JourneyStore(defaults: defaults), provider: traffic, alerts: alerts, clock: { [weak self] in self?.date ?? .distantPast })
        var saved = SavedJourney()
        saved.origin = SavedPlace(name: "Office", address: "1 Example Street", latitude: 37, longitude: -122)
        saved.destination = SavedPlace(name: "Home", address: "Maple Avenue", latitude: 38, longitude: -122)
        watch.settings = saved
        watch.makeUsualRoute()
        traffic.seconds = { [day] date in date < day.addingTimeInterval(17 * 3600 + 30 * 60) ? 55 * 60 : 30 * 60 }
    }
    func at(_ minute: Int) -> Date { day.addingTimeInterval(Double(minute * 60)) }
    func advance(to minute: Int) { date = at(minute); watch.tick() }
    func start() async {
        watch.begin(); await settle { !self.watch.checking }
        if let offer = watch.proposal { assert(watch.acceptOffer(offer)) }
    }
    func clean() { traffic.release(); alerts.release(); alerts.releaseAuthorization(); watch.shutdown(); UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
}
/// What Notification Center still holds, by alert kind (wrapup, leave, risk, unconfirmed), oldest first.
@MainActor func alertKinds(_ alerts: TestAlerts) -> [String] { alerts.posted.map { String($0.split(separator: ".").last ?? "") } }
@MainActor func settle(_ condition: () -> Bool) async {
    for _ in 0..<3000 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
    fatalError("Async test did not settle")
}
@MainActor func runLiveWatchTests() async {
    var scroll = TimeScrollAccumulator()
    assert(scroll.steps(delta: 6, precise: true, timestamp: 1) == 0)
    assert(scroll.steps(delta: 6, precise: true, timestamp: 1.1) == 1)
    assert(scroll.steps(delta: 6, precise: true, timestamp: 1.2) == 0)
    assert(scroll.steps(delta: -6, precise: true, timestamp: 1.3) == 0)
    assert(scroll.steps(delta: -6, precise: true, timestamp: 1.4) == -1)
    assert(scroll.steps(delta: 6, precise: true, timestamp: 2) == 0)
    assert(scroll.steps(delta: 6, precise: true, timestamp: 3) == 0)
    assert(scroll.steps(delta: 1, precise: false, timestamp: 4) == 1)
    assert(scroll.steps(delta: -1, precise: false, timestamp: 5) == -1)
    assert(TimeScrollAccumulator.adjusted(1438, steps: 1, bounds: 0...1439) == 1439)
    assert(TimeScrollAccumulator.adjusted(2, steps: -1, bounds: 0...1439) == 0)
    assert(TimeScrollAccumulator.adjusted(30, steps: 1, bounds: 0...30) == 30)
    assert(TimeScrollAccumulator.adjusted(370, steps: -1, bounds: 0...1439) == 365)
    let ready = LiveFixture(); defer { ready.clean() }
    ready.watch.settings.earliest = 900
    assert(ready.watch.readyMinute == 1025)
    ready.advance(to: 1026)
    assert(ready.watch.readyMinute == 1026)
    ready.watch.settings.earliest = 1040
    assert(ready.watch.makeUsualTimes())
    ready.advance(to: 1027)
    assert(ready.watch.readyMinute == 1040)
    await ready.start()
    let committedLimits = ready.watch.limits
    let committedDeparture = ready.watch.plan?.departure
    ready.advance(to: 1041)
    assert(ready.watch.readyMinute == 1041)
    assert(ready.watch.limits == committedLimits)
    assert(ready.watch.plan?.departure == committedDeparture)
    ready.watch.finish(title: "", message: "")
    ready.advance(to: 1439)
    assert(ready.watch.readyMinute == 1439)
    assert(ready.watch.store.load().earliest == 1040)
    ready.advance(to: 1440 + 1025)
    assert(ready.watch.readyMinute == 1040)
    let reopened = LiveWatch(store: ready.watch.store, provider: ready.traffic, alerts: ready.alerts, clock: { ready.date })
    assert(reopened.readyMinute == 1040)
    reopened.shutdown()

    let f = LiveFixture(); defer { f.clean() }
    await f.start()
    assert(f.watch.plan?.departure == f.at(1050)); assert(f.traffic.requests <= 12)
    assert(f.watch.departureCue == "Wrap up at " + liveTime(f.at(1045)))
    let zeroPacking = LiveFixture(); defer { zeroPacking.clean() }
    zeroPacking.watch.settings.packing = 0
    await zeroPacking.start()
    assert(zeroPacking.watch.departureCue == "No wrap-up needed")
    zeroPacking.advance(to: 1050); await settle { !zeroPacking.watch.checking }
    assert(zeroPacking.watch.departureCue == "Leave now")
    assert(zeroPacking.watch.menuTitle == " Leave now")
    let baseline = f.watch.initialBenefit
    f.advance(to: 1045); await settle { !f.watch.checking && f.watch.cueSubmitted }
    assert(f.watch.plan?.departure == f.at(1050)); assert(f.alerts.posted.count == 1)
    assert(f.watch.departureCue == "Wrap up now")
    f.watch.tick(); assert(f.alerts.posted.count == 1)
    let nudges = LiveFixture(); defer { nudges.clean() }
    await nudges.start()
    nudges.advance(to: 1045); await settle { !nudges.watch.checking && nudges.watch.cueSubmitted }
    assert(nudges.alerts.titles == ["Time to wrap up"])
    nudges.advance(to: 1050); await settle { !nudges.watch.checking && nudges.alerts.titles.count == 2 }
    assert(nudges.alerts.titles == ["Time to wrap up", "Time to leave"])
    nudges.watch.tick(); assert(nudges.alerts.titles.count == 2)
    f.watch.settings.appearance = "Dark"; f.watch.screen = "setup"; f.watch.begin()
    assert(f.watch.plan?.departure == f.at(1050) && f.watch.initialBenefit == baseline)
    f.watch.delay(); await settle { !f.watch.checking }
    assert(f.watch.plan?.departure == f.at(1055)); assert(f.watch.limits?.latest == f.at(1060))
    let check = f.watch.batch?.checkedAt
    f.watch.connectivityChanged(false); assert(f.watch.stale && f.alerts.posted.isEmpty)
    f.advance(to: 1046); assert(f.watch.batch?.checkedAt == check)
    f.watch.connectivityChanged(true); await settle { !f.watch.checking }; assert(!f.watch.stale)
    f.watch.setSleeping(true); assert(f.watch.stale && f.alerts.posted.isEmpty)
    f.watch.setSleeping(false); await settle { !f.watch.checking }; assert(!f.watch.stale)
    f.advance(to: 1056); assert(f.watch.missed && f.watch.plan?.departure == f.at(1055))
    f.watch.finish(title: "Stopped", message: ""); assert(!f.watch.active && f.watch.plan == nil)

    let waitCost = LiveFixture(); defer { waitCost.clean() }
    waitCost.watch.settings.homeBy = 1200
    waitCost.traffic.seconds = { [day = waitCost.day] date in date < day.addingTimeInterval(17 * 3600 + 40 * 60) ? 78 * 60 : 70 * 60 }
    await waitCost.start()
    assert(waitCost.watch.plan?.departure == waitCost.at(1060))
    assert(waitCost.watch.sooner?.departure == waitCost.at(1030))
    assert(!waitCost.watch.wrapUp && waitCost.watch.planComparison != nil)
    waitCost.watch.choose(waitCost.at(1060)); await settle { !waitCost.watch.checking }
    assert(waitCost.watch.planComparison?.contains("Wait 30 min · drive 8 min less · arrive 22 min later") == true)
    waitCost.advance(to: 1055); await settle { !waitCost.watch.checking }
    assert(waitCost.watch.wrapUp && waitCost.watch.planComparison == nil)
    waitCost.watch.connectivityChanged(false)
    assert(waitCost.watch.planComparison == nil && waitCost.watch.drivingAlternative == nil)

    let infeasibleBaseline = LiveFixture(); defer { infeasibleBaseline.clean() }
    infeasibleBaseline.traffic.seconds = { [day = infeasibleBaseline.day] date in date < day.addingTimeInterval(17 * 3600 + 30 * 60) ? 70 * 60 : 30 * 60 }
    await infeasibleBaseline.start()
    assert(infeasibleBaseline.watch.planComparison?.contains("Wait 20 min · drive 40 min less · arrive 20 min earlier") == true)

    let cancelled = LiveFixture(); defer { cancelled.clean() }
    cancelled.traffic.blocked = true; cancelled.watch.begin(); await settle { !cancelled.traffic.waiting.isEmpty }
    cancelled.watch.finish(title: "Stopped", message: ""); cancelled.traffic.release()
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(!cancelled.watch.active && cancelled.watch.batch == nil && cancelled.watch.plan == nil)

    let late = LiveFixture(); defer { late.clean() }
    await late.start()
    late.traffic.blocked = true; late.watch.refresh(); await settle { !late.traffic.waiting.isEmpty }
    late.watch.connectivityChanged(false); late.traffic.release(); try? await Task.sleep(nanoseconds: 20_000_000)
    assert(late.watch.stale && late.watch.plan?.departure == late.at(1050))

    let worsened = LiveFixture(); defer { worsened.clean() }
    await worsened.start()
    worsened.traffic.seconds = { _ in 3 * 3600 }; worsened.watch.delay(); await settle { !worsened.watch.checking }
    assert(worsened.watch.plan == nil && worsened.watch.risk)

    let wrappingRecovery = LiveFixture(); defer { wrappingRecovery.clean() }
    await wrappingRecovery.start()
    wrappingRecovery.advance(to: 1045); await settle { !wrappingRecovery.watch.checking }
    assert(wrappingRecovery.watch.wrapUp && wrappingRecovery.watch.plan?.departure == wrappingRecovery.at(1050))
    wrappingRecovery.date = wrappingRecovery.at(1047)
    wrappingRecovery.traffic.seconds = { _ in 80 * 60 }
    wrappingRecovery.watch.refresh(); await settle { !wrappingRecovery.watch.checking }
    assert(wrappingRecovery.watch.risk && wrappingRecovery.watch.recoveryOptions?.primary.departure == wrappingRecovery.at(1050))
    wrappingRecovery.date = wrappingRecovery.at(1048)
    wrappingRecovery.watch.refresh(); await settle { !wrappingRecovery.watch.checking }
    let imminentRecovery = wrappingRecovery.watch.recoveryOptions!.primary
    assert(imminentRecovery.departure == wrappingRecovery.at(1050))
    wrappingRecovery.date = wrappingRecovery.at(1051)
    wrappingRecovery.watch.refresh(); await settle { !wrappingRecovery.watch.checking }
    let readyRecovery = wrappingRecovery.watch.recoveryOptions!.primary
    assert(readyRecovery.departure == wrappingRecovery.at(1051))
    wrappingRecovery.watch.acceptRecovery(readyRecovery)
    assert(wrappingRecovery.watch.plan == readyRecovery && wrappingRecovery.watch.wrapUp)

    let crossingWrapUp = LiveFixture(); defer { crossingWrapUp.clean() }
    await crossingWrapUp.start()
    crossingWrapUp.date = crossingWrapUp.at(1044)
    crossingWrapUp.traffic.seconds = { _ in 80 * 60 }; crossingWrapUp.traffic.blocked = true
    crossingWrapUp.watch.refresh(); await settle { !crossingWrapUp.traffic.waiting.isEmpty }
    crossingWrapUp.date = crossingWrapUp.at(1047)
    crossingWrapUp.traffic.release(); await settle { !crossingWrapUp.watch.checking }
    assert(crossingWrapUp.watch.recoveryOptions?.primary.departure == crossingWrapUp.at(1050))

    crossingWrapUp.date = crossingWrapUp.at(1048)
    crossingWrapUp.traffic.seconds = { _ in 30 * 60 }
    crossingWrapUp.watch.refresh(); await settle { !crossingWrapUp.watch.checking }
    if let offer = crossingWrapUp.watch.proposal { assert(crossingWrapUp.watch.acceptOffer(offer)) }
    assert(crossingWrapUp.watch.plan?.departure == crossingWrapUp.at(1050))
    crossingWrapUp.date = crossingWrapUp.at(1049)
    crossingWrapUp.traffic.seconds = { _ in 80 * 60 }
    crossingWrapUp.watch.refresh(); await settle { !crossingWrapUp.watch.checking }
    crossingWrapUp.date = crossingWrapUp.at(1061)
    crossingWrapUp.watch.refresh(); await settle { !crossingWrapUp.watch.checking }
    assert(crossingWrapUp.watch.recoveryOptions?.primary.departure == crossingWrapUp.at(1061))
    crossingWrapUp.watch.refresh(replan: true); await settle { !crossingWrapUp.watch.checking }
    assert(crossingWrapUp.watch.recoveryOptions?.primary.departure == crossingWrapUp.at(1066))

    let rescue = LiveFixture(); defer { rescue.clean() }
    rescue.traffic.seconds = { _ in 80 * 60 }
    let savedRescue = rescue.watch.store.load()
    await rescue.start()
    assert(rescue.watch.plan == nil)
    let offered = rescue.watch.recoveryOptions!.primary
    let originalRescueLimits = rescue.watch.limits!
    rescue.watch.acceptRecovery(offered)
    assert(rescue.watch.plan == offered && rescue.watch.wrapUp)
    assert(rescue.watch.limits!.homeBy > originalRescueLimits.homeBy)
    assert(rescue.watch.recoveryOriginalLimits == originalRescueLimits)
    assert(rescue.watch.store.load() == savedRescue)
    rescue.advance(to: 1026)
    assert(rescue.watch.plan == offered)
    let acceptedRescueLimits = rescue.watch.limits
    rescue.watch.settings.appearance = "Dark"; rescue.watch.screen = "setup"; rescue.watch.begin()
    assert(rescue.watch.plan == offered && rescue.watch.limits == acceptedRescueLimits && !rescue.watch.checking)
    rescue.watch.connectivityChanged(false)
    assert(rescue.watch.recoveryOptions == nil)

    let cushion = LiveFixture(); defer { cushion.clean() }
    cushion.traffic.seconds = { _ in 60 * 60 }
    await cushion.start()
    assert(cushion.watch.risk)
    let cushionChoice = cushion.watch.recoveryOptions!.primary
    cushion.watch.acceptRecovery(cushionChoice)
    assert(cushion.watch.limits?.homeBy == cushion.at(1095))
    assert(cushion.watch.limits?.buffer == 300)
    assert(cushion.watch.store.load().homeBy == 1095)
    assert(cushion.watch.details.contains("Spare: 5 min"))

    let refreshAfterAcceptance = LiveFixture(); defer { refreshAfterAcceptance.clean() }
    refreshAfterAcceptance.traffic.seconds = { _ in 80 * 60 }
    await refreshAfterAcceptance.start()
    refreshAfterAcceptance.date = refreshAfterAcceptance.at(1025).addingTimeInterval(179)
    refreshAfterAcceptance.watch.tick()
    let freshChoice = refreshAfterAcceptance.watch.recoveryOptions!.primary
    refreshAfterAcceptance.watch.acceptRecovery(freshChoice)
    let requestsBefore = refreshAfterAcceptance.traffic.requests
    refreshAfterAcceptance.advance(to: 1028)
    await settle { !refreshAfterAcceptance.watch.checking }
    assert(refreshAfterAcceptance.traffic.requests > requestsBefore)

    let outdatedOffer = LiveFixture(); defer { outdatedOffer.clean() }
    outdatedOffer.traffic.seconds = { _ in 80 * 60 }
    await outdatedOffer.start()
    let oldOffer = outdatedOffer.watch.recoveryOptions!.primary
    let unchangedLimits = outdatedOffer.watch.limits
    outdatedOffer.advance(to: 1026)
    outdatedOffer.watch.acceptRecovery(oldOffer)
    assert(outdatedOffer.watch.plan == nil && outdatedOffer.watch.limits == unchangedLimits)
    outdatedOffer.watch.connectivityChanged(false)
    assert(outdatedOffer.watch.recoveryOptions == nil)

    let notification = LiveFixture(); defer { notification.clean() }
    await notification.start()
    notification.alerts.delayed = true; notification.advance(to: 1045)
    await settle { notification.alerts.waiting != nil }
    notification.watch.finish(title: "Stopped", message: ""); notification.alerts.release()
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(notification.alerts.posted.isEmpty)

    let denied = LiveFixture(); defer { denied.clean() }
    denied.alerts.state = .denied; await denied.start()
    denied.advance(to: 1045); await settle { !denied.watch.checking }
    assert(denied.watch.plan != nil && denied.alerts.posted.isEmpty && !denied.watch.cueSubmitted)
    let edits = LiveFixture(); defer { edits.clean() }
    await edits.start()
    edits.advance(to: 1048); await settle { !edits.watch.checking }
    edits.watch.settings.homeBy += 5; await edits.start()
    assert(edits.watch.plan?.departure == edits.at(1050))

    let recovery = LiveFixture(); defer { recovery.clean() }
    await recovery.start()
    recovery.watch.setSleeping(true); recovery.advance(to: 1051); recovery.watch.setSleeping(false)
    assert(recovery.watch.stale && recovery.watch.needsNewDeparture)
    recovery.watch.refresh(replan: recovery.watch.needsNewDeparture); await settle { !recovery.watch.checking }
    assert(!recovery.watch.stale && (recovery.watch.plan == nil || recovery.watch.plan!.departure >= recovery.at(1056)))
    recovery.advance(to: 1062); assert(!recovery.watch.active)

    let expired = LiveFixture(); defer { expired.clean() }
    await expired.start(); expired.advance(to: 1051)
    assert(expired.watch.stale && expired.watch.needsNewDeparture)
    expired.watch.refresh(replan: true); await settle { !expired.watch.checking }; assert(!expired.watch.stale)

    let fresh = LiveFixture(); defer { fresh.clean() }
    await fresh.start()
    fresh.watch.connectivityChanged(false); fresh.advance(to: 1045)
    fresh.traffic.blocked = true; fresh.watch.connectivityChanged(true)
    await settle { fresh.traffic.waiting.isEmpty == false }
    let previousCheck = fresh.watch.batch?.checkedAt
    fresh.watch.settings.homeBy += 5; fresh.watch.begin()
    await settle { fresh.traffic.waiting.count >= 4 }
    fresh.watch.tick(); fresh.watch.maybeNotify()
    assert(fresh.alerts.posted.isEmpty && fresh.watch.stale && fresh.watch.batch?.checkedAt == previousCheck && fresh.watch.plan != nil)
    fresh.traffic.release(); await settle { !fresh.watch.checking && fresh.watch.cueSubmitted }
    assert(fresh.alerts.posted.count == 1)

    let permission = LiveFixture(); defer { permission.clean() }
    permission.alerts.state = .unknown; permission.alerts.delayAuthorization = true
    permission.watch.updateAuthorization(request: false); await settle { permission.alerts.authorizationWaiting != nil }
    permission.watch.updateAuthorization(request: true); permission.alerts.releaseAuthorization()
    await settle { permission.alerts.authorizationCalls.count == 2 }
    assert(permission.alerts.authorizationCalls == [false, true])

    // 1.0.1 item 4: cancelling removes pending alerts only. Delivered alerts stay until
    // the person ends the watch or a new departure replaces them.
    let kept = LiveFixture(); defer { kept.clean() }
    await kept.start()
    kept.advance(to: 1045); await settle { !kept.watch.checking && kept.alerts.titles.count == 1 }
    let wrapID = kept.alerts.posted[0]
    kept.watch.setSleeping(true)
    assert(kept.alerts.posted.contains(wrapID), "sleep keeps the delivered wrap-up alert")
    kept.watch.setSleeping(false); await settle { !kept.watch.checking }
    kept.advance(to: 1050); await settle { !kept.watch.checking && kept.alerts.titles.contains("Time to leave") }
    let leaveID = kept.alerts.posted.last!
    kept.advance(to: 1051)
    assert(kept.watch.missed && kept.alerts.posted.contains(leaveID), "Time to leave stays after the departure minute")
    kept.advance(to: 1062)
    assert(!kept.watch.active && kept.alerts.posted.contains(leaveID), "automatic expiry keeps the delivered leave alert")
    let stopped = LiveFixture(); defer { stopped.clean() }
    await stopped.start()
    stopped.advance(to: 1045); await settle { !stopped.watch.checking && stopped.alerts.titles.count == 1 }
    stopped.watch.stopWatching()
    assert(stopped.alerts.posted.isEmpty, "stopping the watch removes its delivered alerts")
    let replaced = LiveFixture(); defer { replaced.clean() }
    await replaced.start()
    replaced.advance(to: 1045); await settle { !replaced.watch.checking && replaced.alerts.titles.count == 1 }
    replaced.watch.delay(); await settle { !replaced.watch.checking }
    assert(replaced.watch.plan?.departure == replaced.at(1055) && replaced.alerts.posted.isEmpty, "a new departure replaces the old wrap-up alert")
    // Review finding 5: quitting ends the watch, so its alerts go with it (the next launch
    // would remove them anyway).
    let quitting = LiveFixture(); defer { quitting.clean() }
    await quitting.start()
    quitting.advance(to: 1045); await settle { !quitting.watch.checking && alertKinds(quitting.alerts) == ["wrapup"] }
    quitting.watch.shutdown()
    assert(quitting.alerts.posted.isEmpty, "quitting mid-watch removes its delivered alerts")
    // Review finding 2: a withdrawn departure takes its delivered cues with it.
    let withdrawn = LiveFixture(); defer { withdrawn.clean() }
    await withdrawn.start()
    withdrawn.advance(to: 1045); await settle { !withdrawn.watch.checking && alertKinds(withdrawn.alerts) == ["wrapup"] }
    withdrawn.traffic.seconds = { _ in 40 * 60 }
    withdrawn.date = withdrawn.at(1046); withdrawn.watch.refresh()
    await settle { !withdrawn.watch.checking && withdrawn.alerts.titles.count == 2 }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(withdrawn.watch.plan == nil && withdrawn.watch.risk && alertKinds(withdrawn.alerts) == ["risk"],
           "plan to nil: the old wrap-up for 17:30 is removed and only the risk alert remains")
    withdrawn.advance(to: 1062)
    assert(!withdrawn.watch.active && alertKinds(withdrawn.alerts) == ["risk"], "expiry keeps the risk alert and nothing older")
    let rerouted = LiveFixture(); defer { rerouted.clean() }
    await rerouted.start()
    rerouted.advance(to: 1045); await settle { !rerouted.watch.checking && alertKinds(rerouted.alerts) == ["wrapup"] }
    var reroute = rerouted.watch.makeDraft()
    reroute.value.destination = SavedPlace(name: "Gym", address: "2 Other Street", latitude: 38.5, longitude: -122)
    assert(rerouted.watch.applyDraft(reroute) == nil); await settle { !rerouted.watch.checking }
    assert(rerouted.watch.active && rerouted.watch.plan == nil && rerouted.alerts.posted.isEmpty,
           "edit while watching: a new route removes the old route's Leave at 17:30")
    rerouted.advance(to: 1062)
    assert(rerouted.alerts.posted.isEmpty, "nothing from the old route comes back after expiry")
    let retimed = LiveFixture(); defer { retimed.clean() }
    await retimed.start()
    retimed.advance(to: 1045); await settle { !retimed.watch.checking && alertKinds(retimed.alerts) == ["wrapup"] }
    var tighter = retimed.watch.makeDraft(); tighter.value.packing = 10
    assert(retimed.watch.applyDraft(tighter) == nil); await settle { !retimed.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(retimed.watch.limits?.packing == 600 && !alertKinds(retimed.alerts).contains("wrapup"),
           "edit while watching: a same-route edit that drops the plan removes its wrap-up")
    let missedReplan = LiveFixture(); defer { missedReplan.clean() }
    await missedReplan.start()
    missedReplan.advance(to: 1045); await settle { !missedReplan.watch.checking && missedReplan.alerts.titles.count == 1 }
    missedReplan.advance(to: 1050); await settle { !missedReplan.watch.checking && missedReplan.alerts.titles.count == 2 }
    missedReplan.advance(to: 1052)
    assert(missedReplan.watch.missed && alertKinds(missedReplan.alerts) == ["wrapup", "leave"], "fixture: departure missed, cues kept")
    assert(missedReplan.watch.recheck(replan: true)); await settle { !missedReplan.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(!alertKinds(missedReplan.alerts).contains("wrapup") && !alertKinds(missedReplan.alerts).contains("leave"),
           "replan after a missed departure: the 17:30 cues are removed")
    assert(missedReplan.watch.plan != nil || alertKinds(missedReplan.alerts) == ["risk"],
           "replan with nothing chosen leaves only the risk alert")

    // 1.0.1 item 3: one wrap-up and one leave alert per accepted departure, across pauses.
    let once = LiveFixture(); defer { once.clean() }
    await once.start()
    func count(_ title: String) -> Int { once.alerts.titles.filter { $0 == title }.count }
    once.advance(to: 1045); await settle { !once.watch.checking && count("Time to wrap up") == 1 }
    once.watch.setSleeping(true); once.watch.setSleeping(false); await settle { !once.watch.checking }
    once.date = once.at(1046); once.watch.connectivityChanged(false); once.watch.connectivityChanged(true)
    await settle { !once.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(count("Time to wrap up") == 1 && alertKinds(once.alerts) == ["wrapup"],
           "sleep or a connection blip neither repeats nor removes Time to wrap up")
    once.traffic.fails = { _ in true }; once.watch.refresh(); await settle { !once.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(once.watch.stale && alertKinds(once.alerts) == ["unconfirmed"], "a failed check replaces the cue with the warning")
    once.traffic.fails = { _ in false }; once.date = once.at(1047)
    assert(once.watch.recheck()); await settle { !once.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(!once.watch.stale && alertKinds(once.alerts) == ["wrapup"],
           "after a successful recheck the warning is gone and the current cue is back in Notification Center")
    once.advance(to: 1050); await settle { !once.watch.checking && count("Time to leave") == 1 }
    once.watch.setSleeping(true); once.watch.setSleeping(false); await settle { !once.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(count("Time to leave") == 1 && alertKinds(once.alerts) == ["wrapup", "leave"],
           "waking at the departure time neither repeats nor removes Time to leave")
    once.watch.delay(); await settle { !once.watch.checking && alertKinds(once.alerts) == ["wrapup"] }
    assert(once.watch.plan?.departure == once.at(1055), "a new departure time replaces the old cues and may alert again")

    // Review finding 3: one failing streak sends one "Check your departure", across sleep and reconnects.
    let streak = LiveFixture(); defer { streak.clean() }
    await streak.start()
    streak.advance(to: 1040); await settle { !streak.watch.checking }
    streak.traffic.fails = { _ in true }
    streak.date = streak.at(1041); streak.watch.refresh(); await settle { !streak.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    streak.watch.setSleeping(true); streak.date = streak.at(1042); streak.watch.setSleeping(false); await settle { !streak.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    streak.watch.connectivityChanged(false); streak.watch.connectivityChanged(true); await settle { !streak.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(streak.watch.stale && streak.alerts.titles == ["Check your departure"] && alertKinds(streak.alerts) == ["unconfirmed"],
           "a failing streak warns once, however often the Mac sleeps or reconnects")
    streak.traffic.fails = { _ in false }; streak.date = streak.at(1043)
    assert(streak.watch.recheck()); await settle { !streak.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(!streak.watch.stale && streak.alerts.posted.isEmpty, "recovery withdraws the warning")
    streak.traffic.fails = { _ in true }; streak.date = streak.at(1044); streak.watch.refresh()
    await settle { !streak.watch.checking && streak.alerts.titles.count == 2 }
    assert(alertKinds(streak.alerts) == ["unconfirmed"], "a new failure after recovery may warn again")

    // Review finding 6: waking inside the leave minute still confirms traffic and sends Time to leave.
    let lateWake = LiveFixture(); defer { lateWake.clean() }
    await lateWake.start()
    lateWake.advance(to: 1040); await settle { !lateWake.watch.checking }
    lateWake.watch.setSleeping(true)
    lateWake.date = lateWake.at(1050).addingTimeInterval(20)
    lateWake.watch.setSleeping(false); await settle { !lateWake.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    lateWake.date = lateWake.at(1050).addingTimeInterval(40); lateWake.watch.tick()
    await settle { !lateWake.watch.checking && lateWake.alerts.titles.count == 1 }
    assert(!lateWake.watch.stale && lateWake.watch.plan?.departure == lateWake.at(1050) && lateWake.watch.cuePhase == .leaveNow,
           "waking 20 s into the leave minute rechecks the watched departure instead of calling it passed")
    assert(lateWake.alerts.titles == ["Time to leave"] && alertKinds(lateWake.alerts) == ["leave"], "and Time to leave goes out")

    // Gemini claim 2: a check that fails just before departure is retried within a minute,
    // so one blip does not cost the leave alert.
    let blip = LiveFixture(); defer { blip.clean() }
    await blip.start()
    blip.advance(to: 1045); await settle { !blip.watch.checking && alertKinds(blip.alerts) == ["wrapup"] }
    blip.traffic.fails = { _ in true }
    blip.date = blip.at(1048); blip.watch.refresh(); await settle { !blip.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(blip.watch.stale && alertKinds(blip.alerts) == ["unconfirmed"], "fixture: a check fails two minutes before departure")
    blip.traffic.fails = { _ in false }
    blip.date = blip.at(1048).addingTimeInterval(30); blip.watch.tick(); await settle { !blip.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(!blip.watch.stale && alertKinds(blip.alerts) == ["wrapup"], "the check is retried 30 s later, not at the next 3-minute refresh")
    blip.advance(to: 1050); await settle { !blip.watch.checking && blip.alerts.titles.contains("Time to leave") }
    assert(alertKinds(blip.alerts) == ["wrapup", "leave"], "Time to leave still arrives")
    let calm = LiveFixture(); defer { calm.clean() }
    await calm.start()
    calm.traffic.fails = { _ in true }
    calm.date = calm.at(1030); calm.watch.refresh(); await settle { !calm.watch.checking }
    let calmRequests = calm.traffic.requests
    calm.date = calm.at(1030).addingTimeInterval(60); calm.watch.tick()
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(calm.traffic.requests == calmRequests, "with no cue due before the next regular check, a failure waits for it")

    // Gemini claim 1: when Apple Maps throttles, stop the check and wait a minute before retrying.
    let throttled = LiveFixture(); defer { throttled.clean() }
    throttled.traffic.throttles = { _ in true }; throttled.watch.begin(); await settle { !throttled.watch.checking }
    assert(throttled.watch.checkingExpectedCount > 2 && throttled.traffic.requests == 2,
           "a throttled check stops after the first pair instead of firing every remaining request")
    assert(throttled.watch.stale && throttled.watch.pauseReason?.contains("isn’t responding") == true, "and says Apple Maps isn't responding")
    let paced = LiveFixture(); defer { paced.clean() }
    await paced.start()
    paced.advance(to: 1045); await settle { !paced.watch.checking && alertKinds(paced.alerts) == ["wrapup"] }
    paced.traffic.throttles = { _ in true }
    paced.date = paced.at(1047); paced.watch.refresh(); await settle { !paced.watch.checking }
    let pacedRequests = paced.traffic.requests
    paced.date = paced.at(1047).addingTimeInterval(30); paced.watch.tick()
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(paced.traffic.requests == pacedRequests, "no 30 s retry after throttling, even with a cue due")
    paced.traffic.throttles = { _ in false }
    paced.date = paced.at(1048); paced.watch.tick(); await settle { !paced.watch.checking }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(paced.traffic.requests > pacedRequests && !paced.watch.stale, "the retry comes a minute later")

    // 1.0.1 item 2: a watched departure that still fits is never swapped for an offer,
    // even when a later time drives less, and it keeps both nudges.
    let stable = LiveFixture(); defer { stable.clean() }
    await stable.start()
    stable.traffic.seconds = { [day = stable.day] date in date < day.addingTimeInterval(17 * 3600 + 35 * 60) ? 30 * 60 : 18 * 60 }
    stable.advance(to: 1045); await settle { !stable.watch.checking && stable.alerts.titles.count == 1 }
    assert(stable.watch.proposal == nil && stable.watch.plan?.departure == stable.at(1050), "a fitting watched departure stays committed")
    stable.advance(to: 1050); await settle { !stable.watch.checking && stable.alerts.titles.count == 2 }
    assert(stable.alerts.titles == ["Time to wrap up", "Time to leave"], "a fitting watched departure keeps both nudges")
    // When the watched departure stops fitting, the offer needs the person's choice, and
    // the alert that says so stays in Notification Center after the offer expires.
    let offeredWatch = LiveFixture(); defer { offeredWatch.clean() }
    await offeredWatch.start()
    offeredWatch.traffic.seconds = { [day = offeredWatch.day] date in date < day.addingTimeInterval(17 * 3600 + 35 * 60) ? 60 * 60 : 20 * 60 }
    offeredWatch.date = offeredWatch.at(1030); offeredWatch.watch.refresh()
    await settle { !offeredWatch.watch.checking && offeredWatch.alerts.titles == ["Check your departure"] }
    let attention = offeredWatch.alerts.posted[0], frozenOffer = offeredWatch.watch.proposal
    assert(frozenOffer?.choice.departure == offeredWatch.at(1055) && offeredWatch.watch.plan == nil, "fixture: the watched time no longer fits")
    let offeredRequests = offeredWatch.traffic.requests
    for minute in [1033, 1036, 1045, 1050] { offeredWatch.advance(to: minute) }
    try? await Task.sleep(nanoseconds: 20_000_000)
    assert(offeredWatch.watch.plan == nil && offeredWatch.watch.proposal == frozenOffer && offeredWatch.traffic.requests == offeredRequests,
           "the offer is never accepted on the person's behalf and stays frozen until they recheck")
    assert(offeredWatch.watch.stale && offeredWatch.alerts.posted == [attention] && offeredWatch.alerts.titles == ["Check your departure"],
           "after the offer expires, the alert saying the watch needs attention is still delivered")

    // 1.0.1 item 5: idle, the clock publishes only when the displayed minute or the day changes.
    @MainActor final class PublishCounter {
        var count = 0
        #if WINDOW_PORTABLE_TESTS
        init(_ watch: LiveWatch) { PortablePublications.willChange = { [unowned self] in self.count += 1 } }
        func stop() { PortablePublications.willChange = nil }
        #else
        var sink: AnyCancellable?
        init(_ watch: LiveWatch) { sink = watch.objectWillChange.sink { [unowned self] _ in self.count += 1 } }
        func stop() { sink?.cancel() }
        #endif
    }
    let idle = LiveFixture(); defer { idle.clean() }
    idle.date = idle.at(1040); idle.watch.tick()
    let idleMinute = PublishCounter(idle.watch)
    for second in 1...60 { idle.date = idle.at(1040).addingTimeInterval(Double(second)); idle.watch.tick() }
    idleMinute.stop()
    fputs("Idle minute: \(idleMinute.count) publishes over 60 one-second ticks\n", stderr)
    assert(idleMinute.count == 1 && idle.watch.now == idle.at(1041), "an idle minute publishes once, when the minute changes")
    idle.date = idle.at(1439).addingTimeInterval(59); idle.watch.tick()
    let dayBefore = idle.watch.dayKey
    idle.date = idle.at(1440); idle.watch.tick()
    assert(idle.watch.dayKey != dayBefore && idle.watch.now == idle.at(1440), "midnight still reaches an idle watch on the first tick")
    let undoing = LiveFixture(); defer { undoing.clean() }
    await undoing.start()
    let stopTime = undoing.date
    undoing.watch.stopWatching()
    undoing.date = stopTime.addingTimeInterval(7); undoing.watch.tick()
    assert(undoing.watch.canUndoStop, "Undo is offered for the full undo window")
    undoing.date = stopTime.addingTimeInterval(LiveWatch.undoStopSeconds + 0.5); undoing.watch.tick()
    assert(!undoing.watch.canUndoStop && undoing.watch.now == undoing.date, "Undo disappears on the first tick after its window")
    let ticking = LiveFixture(); defer { ticking.clean() }
    await ticking.start()
    ticking.date = ticking.date.addingTimeInterval(1); ticking.watch.tick()
    assert(ticking.watch.now == ticking.date, "an active watch still reads the clock every second")

    print("PASS: real-clock controller, bounded refresh, wrap-up once, settings preserve plan, exact delay, offline and sleep recovery, missed departure, cancellation, late response, rejected delay with worsened traffic, late alert cleanup, denied alerts, feasible limit edits, sleeping past departure, expired missed-plan recovery, watch expiry, queued permission request, no cue without replacement evidence")
}

#if !WINDOW_PORTABLE_TESTS && !WINDOW_CORE_TESTS
@MainActor func arrangeLivePreview(_ f: LiveFixture, name: String, appearance: String) async {
    f.watch.settings.appearance = appearance
    if name == "checking" { f.traffic.blocked = true }
    if ["denied", "wrapup-denied"].contains(name) { f.alerts.state = .denied }
    if name == "zero-packing" { f.watch.settings.packing = 0 }
    if !["setup", "first-launch", "home"].contains(name) { f.watch.begin(); if name != "checking" { await settle { !f.watch.checking }; if name != "suggested", let offer = f.watch.proposal { assert(f.watch.acceptOffer(offer)) } } }
    switch name {
    case "first-launch": f.watch.settings.origin = nil; f.watch.settings.destination = nil
    case "home": f.watch.screen = "home"
    case "due": f.advance(to: 1050); await settle { !f.watch.checking }
    case "pending": f.traffic.blocked = true; f.watch.delay(); await settle { !f.traffic.waiting.isEmpty }
    case "today-override":
        f.watch.finish(title: "", message: ""); var draft = f.watch.makeDraft(); draft.value.homeBy = 1200; _ = f.watch.applyDraft(draft)
    case "zero-packing": f.advance(to: 1050); await settle { !f.watch.checking }
    case "wrapup", "wrapup-denied": f.advance(to: 1045); await settle { !f.watch.checking }
    case "offline": f.watch.connectivityChanged(false)
    case "risk", "risk-alternative":
        f.traffic.seconds = { [day = f.day] date in date < day.addingTimeInterval(17 * 3600 + 25 * 60) ? 80 * 60 : 70 * 60 }
        f.watch.refresh(); await settle { !f.watch.checking }
    case "wait-cost":
        f.watch.finish(title: "", message: ""); f.watch.settings.homeBy = 1200
        f.traffic.seconds = { [day = f.day] date in date < day.addingTimeInterval(17 * 3600 + 40 * 60) ? 78 * 60 : 70 * 60 }
        await f.start()
    case "wait-chosen":
        f.watch.finish(title: "", message: ""); f.watch.settings.homeBy = 1200
        f.traffic.seconds = { [day = f.day] date in date < day.addingTimeInterval(17 * 3600 + 40 * 60) ? 78 * 60 : 70 * 60 }
        await f.start()
        f.watch.choose(f.at(1060)); await settle { !f.watch.checking }
    case "risk-cushion": f.traffic.seconds = { _ in 60 * 60 }; f.watch.refresh(); await settle { !f.watch.checking }
    case "risk-empty": f.advance(to: 1060); f.watch.refresh(replan: true); await settle { !f.watch.checking }
    case "recovery-accepted":
        f.traffic.seconds = { _ in 80 * 60 }; f.watch.refresh(); await settle { !f.watch.checking }
        if let choice = f.watch.recoveryOptions?.primary { f.watch.acceptRecovery(choice) }

    case "missed": f.advance(to: 1051)
    case "finished": f.watch.finish(title: "You’re on your way.", message: "The watch has ended. Your usual journey is saved.")
    case "long-names":
        f.watch.settings.origin = SavedPlace(name: "Riverside Innovation Campus, Building 7", address: "100 Innovation Way", latitude: 37, longitude: -122)
        f.watch.settings.destination = SavedPlace(name: "Grandmother’s house in Maple Hollow", address: "12 Hollow Road", latitude: 38, longitude: -122)
        f.watch.finish(title: "", message: ""); await f.start()
    default: break
    }
}

// The legacy main window only exists outside the native build.
#if !WINDOW_NATIVE
@MainActor func snapshotLive(into directory: String) async {
    var overflow = 0
    var rendered = 0
    let accessible = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    for name in ["setup", "first-launch", "home", "checking", "watch", "wrapup", "zero-packing", "denied", "wrapup-denied", "offline", "risk", "risk-cushion", "risk-empty", "recovery-accepted", "wait-cost", "wait-chosen", "missed", "finished", "long-names", "suggested", "due", "pending", "today-override"] {
        for compact in [false, true] {
        for mode in ["Light", "Dark"] {
          // SwiftUI reads contrast from the OS accessibility setting. Named
          // NSAppearance alone produces duplicate normal-contrast captures.
          for (variant, scale, size) in [
            (accessible ? "-high-contrast" : "", 1.0, NSSize(width: 420, height: 510)),
            (accessible ? "-largest-high-contrast" : "-largest", 1.4, NSSize(width: 600, height: 720))
          ] {
            let f = LiveFixture(); defer { f.clean() }
            await arrangeLivePreview(f, name: name, appearance: mode)
            let view = LiveWindowView(watch: f.watch, announces: false, compact: compact)
                .environment(\.windowTextScale, scale)
            let controller = NSHostingController(rootView: view)
            let host = controller.view
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: accessible ? (mode == "Dark" ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (mode == "Dark" ? .darkAqua : .aqua)); window.contentView = host
            host.layoutSubtreeIfNeeded()
            let measurement = NSHostingController(rootView: LiveWindowView(watch: f.watch, measuring: true, announces: false, compact: compact)
                .environment(\.windowTextScale, scale))
            measurement.view.appearance = window.appearance
            let needed = measurement.sizeThatFits(in: NSSize(width: size.width, height: 100000))
            rendered += 1
            let tag = "live-\(name)-\(mode.lowercased())\(variant)\(compact ? "-panel" : "")"
            if needed.height > size.height { overflow += 1 }
            print("\(tag): needs \(Int(size.width)) × \(Int(needed.height))\(needed.height > size.height ? " OVERFLOW" : "")")
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/\(tag).png"))
            }
            if name == "checking" || name == "pending" { f.watch.finish(title: "", message: ""); f.traffic.release() }
          }
        }
    }
    }
    print("Increase Contrast is \(accessible ? "on" : "off"); the opposite setting was NOT TESTED.")
    print(overflow == 0 ? "PASS: \(rendered) live layouts fit standard and largest-text configurations at the current OS contrast setting" : "FAIL: \(overflow) live states overflow")
    exit(overflow == 0 ? 0 : 1)
}
#endif

#endif
