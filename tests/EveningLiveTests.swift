import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

@MainActor final class EveningTraffic: TrafficProviding {
    var duration: (Date) -> TimeInterval = { _ in 30 * 60 }
    var blocked = false
    var fail = false
    var requests: [Date] = []
    var waiting: [(Date, CheckedContinuation<DepartureEstimate, Error>)] = []
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        requests.append(departing)
        if fail { throw NSError(domain: "fixture", code: 1) }
        if blocked { return try await withCheckedThrowingContinuation { waiting.append((departing, $0)) } }
        return DepartureEstimate(departure: departing, driving: duration(departing))
    }
    func release() {
        blocked = false
        let pending = waiting; waiting = []
        for (date, continuation) in pending { continuation.resume(returning: DepartureEstimate(departure: date, driving: duration(date))) }
    }
}
@MainActor final class EveningAlerts: WatchAlerting {
    var state = AlertAuthorization.allowed
    var calls: [Bool] = []
    var posted: [String: String] = [:]
    var deliveries: [String] = []
    var removed: [String] = []
    var delayed = false
    var failing = false
    var waiting: CheckedContinuation<Void, Never>?
    func authorization(request: Bool) async -> AlertAuthorization { calls.append(request); return state }
    func deliver(id: String, title: String, body: String) async throws {
        if failing { throw NSError(domain: "alert-fixture", code: 1) }
        if delayed { await withCheckedContinuation { waiting = $0 } }
        posted[id] = title; deliveries.append(id)
    }
    func remove(ids: [String]) { for id in ids { posted[id] = nil }; removed += ids }
    func release() { delayed = false; waiting?.resume(); waiting = nil }
}
@MainActor final class EveningFixture {
    let suite = "window-evening-live-\(UUID().uuidString)"
    let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    var date: Date
    let traffic = EveningTraffic()
    let alerts = EveningAlerts()
    var watch: LiveWatch!
    init(hasUsualRoute: Bool = true) {
        date = day.addingTimeInterval(1025 * 60)
        var journey = SavedJourney()
        if hasUsualRoute {
            journey.origin = SavedPlace(name: "Office", address: "Test office", latitude: 37, longitude: -122)
            journey.destination = SavedPlace(name: "Home", address: "Test home", latitude: 38, longitude: -122)
        }
        let store = JourneyStore(defaults: UserDefaults(suiteName: suite)!)
        store.save(journey)
        traffic.duration = { [day] date in date < day.addingTimeInterval(1050 * 60) ? 55 * 60 : 30 * 60 }
        watch = LiveWatch(store: store, provider: traffic, alerts: alerts, clock: { [weak self] in self?.date ?? .distantPast })
    }
    func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }
    func advance(_ minute: Double) { date = at(minute); watch.tick() }
    func start() async {
        watch.begin(); await until { !self.watch.checking }
        if let offer = watch.proposal { precondition(watch.acceptOffer(offer)) }
        await until { !self.alerts.calls.isEmpty }
    }
    func clean() { traffic.release(); alerts.release(); watch.shutdown(); UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
}
@MainActor func until(_ failure: String = "Async test did not settle", _ condition: () -> Bool) async {
    for _ in 0..<4000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    fatalError(failure)
}
#if !WINDOW_CORE_TESTS
@main
#endif
struct EveningLiveTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(name)") }
    }
    @MainActor static func main() async {
        let f = EveningFixture(); defer { f.clean() }
        f.watch.begin(); await until { !f.watch.checking }
        expect(f.watch.plan == nil && f.watch.proposal?.choice.departure == f.at(1050), "suggestion is not a commitment")
        expect(f.alerts.calls.allSatisfy { !$0 } && f.alerts.posted.isEmpty, "no permission prompt or alert before acceptance")
        let offer = f.watch.proposal!
        expect(f.watch.acceptOffer(offer), "accept checked departure")
        expect(f.watch.plan?.departure == f.at(1050) && f.watch.proposal == nil, "one committed time")
        await until { f.alerts.calls.contains(true) }
        expect(f.traffic.requests.count <= 12, "bounded batch")
        let committed = f.watch.plan
        f.advance(1045); await until { !f.watch.checking && f.watch.cueSubmitted }
        expect(f.watch.plan == committed && f.watch.departureCue == "Wrap up now", "preparation preserves commitment")
        let firstAlertCount = f.alerts.deliveries.count
        f.advance(1050); await until { !f.watch.checking && f.alerts.deliveries.count > firstAlertCount }
        expect(f.watch.departureCue == "Leave now" && f.watch.menuTitle == " Leave now", "screen and menu agree at due")
        expect(f.alerts.deliveries.count == firstAlertCount + 1, "one leave notification at departure")
        f.advance(1050.1); try? await Task.sleep(nanoseconds: 20_000_000)
        expect(f.alerts.deliveries.count == firstAlertCount + 1, "no duplicate due notification")
        f.date = f.at(1050.2); f.traffic.blocked = true; f.watch.delay()
        expect(f.watch.pendingDeparture == f.at(1055), "pending time named immediately")
        expect(f.watch.plan == committed, "request does not optimistically move clock")
        await until { !f.traffic.waiting.isEmpty }; f.traffic.release(); await until { !f.watch.checking }
        expect(f.watch.plan?.departure == f.at(1055) && f.watch.pendingDeparture == nil, "exact delay accepted in due grace")
        expect(f.watch.limits?.latest == f.at(1060), "delay keeps latest departure")

        let edit = EveningFixture(); defer { edit.clean() }
        let saved = edit.watch.store.load()
        var draft = edit.watch.makeDraft(); draft.value.homeBy = 1200
        expect(edit.watch.store.loadToday(on: edit.date).homeBy == saved.homeBy, "editing does not write through")
        expect(edit.watch.applyDraft(draft) == nil, "apply today")
        expect(edit.watch.store.load().homeBy == saved.homeBy, "usual time intact")
        expect(edit.watch.store.loadToday(on: edit.date).homeBy == 1200, "today persists")
        let reopened = LiveWatch(store: edit.watch.store, provider: edit.traffic, alerts: edit.alerts, clock: { edit.date })
        expect(reopened.settings.homeBy == 1200 && !reopened.active, "relaunch restores daily choice but no watch")
        reopened.shutdown()
        expect(edit.watch.applyDraft(draft) != nil, "concurrent stale draft rejected")
        expect(edit.watch.makeUsualTimes(), "explicit promotion")
        expect(edit.watch.store.load().homeBy == 1200, "usual times changed only explicitly")
        let appearanceDraft = edit.watch.makeDraft()
        edit.watch.settings.appearance = "Dark"
        expect(edit.watch.applyDraft(appearanceDraft) == nil && edit.watch.settings.appearance == "Dark", "appearance change does not discard edit or revert theme")
        var yesterday = edit.watch.makeDraft(); yesterday.value.homeBy = 1300
        edit.date = edit.at(1440 + 1025)
        expect(edit.watch.applyDraft(yesterday) != nil, "action notices midnight before timer")
        expect(edit.watch.settings.homeBy == 1200, "new day loads usual settings")

        let firstRoute = EveningFixture(hasUsualRoute: false); defer { firstRoute.clean() }
        expect(firstRoute.watch.usualSettings.routeID == nil, "first route starts without a usual route")
        var routeDraft = firstRoute.watch.makeDraft()
        routeDraft.value.origin = f.watch.settings.origin
        routeDraft.value.destination = f.watch.settings.destination
        routeDraft.value.homeBy = 1200
        let routeID = routeDraft.value.routeID
        expect(firstRoute.watch.applyDraft(routeDraft) == nil, "first route can be accepted for today")
        expect(firstRoute.watch.usualSettings.routeID == nil && firstRoute.watch.store.load().routeID == nil,
               "accepting the first daily route does not save a usual route")
        let routeReload = LiveWatch(store: firstRoute.watch.store, provider: firstRoute.traffic,
                                    alerts: firstRoute.alerts, clock: { firstRoute.date })
        expect(routeReload.settings.routeID == routeID && routeReload.usualSettings.routeID == nil && !routeReload.active,
               "same-day relaunch restores first daily route without a usual route or active watch")
        routeReload.shutdown()
        let tomorrow = firstRoute.at(1440 + 1025)
        let nextDayRoute = LiveWatch(store: firstRoute.watch.store, provider: firstRoute.traffic,
                                     alerts: firstRoute.alerts, clock: { tomorrow })
        expect(nextDayRoute.settings.routeID == nil && nextDayRoute.usualSettings.routeID == nil,
               "next-day relaunch does not inherit an unsaved usual route")
        nextDayRoute.shutdown()
        firstRoute.watch.makeUsualRoute()
        expect(firstRoute.watch.usualSettings.routeID == routeID && firstRoute.watch.store.load().routeID == routeID,
               "explicit usual-route action persists the first route")
        expect(firstRoute.watch.store.loadToday(on: tomorrow).routeID == routeID,
               "explicitly saved usual route is available on the next day")
        expect(firstRoute.watch.store.load().homeBy == 1095,
               "explicit usual-route save does not also save daily times")

        let promote = EveningFixture(); defer { promote.clean() }
        var today = promote.watch.makeDraft(); today.value.homeBy = 1200
        expect(promote.watch.applyDraft(today) == nil, "daily change before rollover")
        promote.date = promote.at(1440 + 1025)
        expect(!promote.watch.makeUsualTimes(), "no promotion of yesterday from stale UI")
        expect(promote.watch.store.load().homeBy == 1095, "usual times survive rollover click")

        let expired = EveningFixture(); defer { expired.clean() }
        expired.watch.begin(); await until { !expired.watch.checking }
        let expiredOffer = expired.watch.proposal!
        expired.date = expired.at(1030)
        expect(!expired.watch.acceptOffer(expiredOffer) && expired.watch.plan == nil, "offer expiry at click")
        expect(expired.alerts.posted.isEmpty, "expired offer cannot arm alerts")

        let cancelled = EveningFixture(); defer { cancelled.clean() }
        cancelled.traffic.blocked = true; cancelled.watch.begin()
        await until { !cancelled.traffic.waiting.isEmpty }
        cancelled.watch.finish(title: "Watch stopped.", message: "No alerts remain.")
        cancelled.traffic.release(); try? await Task.sleep(nanoseconds: 20_000_000)
        expect(!cancelled.watch.active && cancelled.watch.plan == nil && cancelled.watch.proposal == nil, "late response cannot resurrect stopped watch")
        expect(cancelled.watch.limits == nil && cancelled.watch.route == nil, "ended details cleared")

        let late = EveningFixture(); defer { late.clean() }
        await late.start(); let old = late.watch.plan
        late.traffic.blocked = true; late.watch.delay(); await until { !late.traffic.waiting.isEmpty }
        late.date = late.at(1031); late.traffic.release(); await until { !late.watch.checking }
        expect(late.watch.plan == old && late.watch.stale && late.watch.pendingDeparture == nil, "a batch finishing after expiry cannot move the plan")

        let offline = EveningFixture(); defer { offline.clean() }
        await offline.start(); let beforeOffline = offline.watch.plan
        offline.traffic.blocked = true; offline.watch.delay(); await until { !offline.traffic.waiting.isEmpty }
        offline.watch.connectivityChanged(false); offline.traffic.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(offline.watch.stale && offline.watch.plan == beforeOffline && offline.watch.pendingDeparture == nil, "offline cancels pending update")
        offline.watch.connectivityChanged(true); await until { !offline.watch.checking }
        expect(!offline.watch.stale && offline.watch.plan == beforeOffline, "reconnect revalidates commitment")
        offline.watch.setSleeping(true); offline.advance(1051); offline.watch.setSleeping(false)
        expect(offline.watch.stale && offline.watch.needsNewDeparture, "wake past departure does not invent a plan")

        let denied = EveningFixture(); defer { denied.clean() }
        denied.alerts.state = .denied; await denied.start()
        denied.advance(1045); await until { !denied.watch.checking }
        expect(denied.watch.plan != nil && denied.alerts.posted.isEmpty, "denied alerts do not remove estimates")

        let failed = EveningFixture(); defer { failed.clean() }
        await failed.start(); let previous = failed.watch.plan
        failed.traffic.fail = true; failed.watch.delay(); await until { !failed.watch.checking }
        expect(failed.watch.stale && failed.watch.plan == previous && failed.watch.pendingDeparture == nil, "failed delay retains only an unconfirmed prior plan")

        let risk = EveningFixture(); defer { risk.clean() }
        await risk.start(); risk.advance(1045); await until { !risk.watch.checking }
        risk.date = risk.at(1047); risk.traffic.duration = { _ in 80 * 60 }
        risk.watch.refresh(); await until { !risk.watch.checking }
        let recovery = risk.watch.recoveryOptions!.primary
        expect(recovery.departure == risk.at(1050), "recovery does not restart preparation")
        let recoverOffer = risk.watch.offer(for: recovery, recovery: true)!
        let savedRisk = risk.watch.store.load()
        expect(risk.watch.acceptOffer(recoverOffer), "explicit recovery consent")
        expect(risk.watch.store.load() == savedRisk && risk.watch.recoveryOriginalLimits != nil, "recovery never changes saved schedule")
        let limitsBeforeEdit = risk.watch.limits
        expect(risk.watch.applyDraft(risk.watch.makeDraft()) == nil && risk.watch.limits == limitsBeforeEdit, "unchanged edit retains recovery consent")

        let changed = EveningFixture(); defer { changed.clean() }
        await changed.start()
        let earlier = changed.watch.sooner!
        let frozen = changed.watch.offer(for: earlier, baseline: changed.watch.plan)!
        changed.traffic.duration = { _ in 42 * 60 }; changed.watch.refresh(); await until { !changed.watch.checking }
        expect(!changed.watch.acceptOffer(frozen), "refresh invalidates rather than rewrites comparison consent")
        expect(frozen.choice == earlier, "displayed offer remains immutable")

        let preparation = EveningFixture(); defer { preparation.clean() }
        await preparation.start()
        preparation.traffic.duration = { _ in 30 * 60 }
        preparation.date = preparation.at(1043); preparation.watch.refresh()
        await until { !preparation.watch.checking }
        let originalPreparationPlan = preparation.watch.plan!
        let earlierPreparationOffer = preparation.watch.offer(for: preparation.watch.sooner!, baseline: originalPreparationPlan)!
        expect(earlierPreparationOffer.choice.departure == preparation.at(1048) && preparation.watch.canAccept(earlierPreparationOffer),
               "earlier frozen departure initially leaves the full five-minute preparation interval")
        preparation.advance(1044)
        expect(!preparation.watch.canAccept(earlierPreparationOffer), "earlier departure expires when a full preparation interval no longer fits")
        preparation.advance(1045)
        expect(preparation.watch.departureCue == "Wrap up now", "original preparation interval has only just started")
        expect(!preparation.watch.canAccept(earlierPreparationOffer), "starting wrap-up cannot make an expired earlier offer eligible again")
        expect(!preparation.watch.acceptOffer(earlierPreparationOffer) && preparation.watch.plan == originalPreparationPlan,
               "acceptance retains the original departure when the earlier choice cuts preparation short")
        let preparationRequests = preparation.traffic.requests.count
        preparation.watch.choose(earlierPreparationOffer.choice.departure)
        expect(!preparation.watch.checking && preparation.traffic.requests.count == preparationRequests && preparation.watch.plan == originalPreparationPlan,
               "direct departure requests also reject a choice that cuts preparation short")
        preparation.date = preparation.at(1047); preparation.watch.synchronizeDay()
        let retainedPreparationOffer = preparation.watch.offer(for: originalPreparationPlan)!
        expect(preparation.watch.canAccept(retainedPreparationOffer), "preparation already underway still completes at the original departure")

        let preparationResponse = EveningFixture(); defer { preparationResponse.clean() }
        await preparationResponse.start()
        let beforePreparationRequest = preparationResponse.watch.plan
        preparationResponse.traffic.duration = { _ in 30 * 60 }
        preparationResponse.traffic.blocked = true
        preparationResponse.date = preparationResponse.at(1029)
        preparationResponse.watch.choose(preparationResponse.at(1035))
        await until("Preparation-response fixture must begin a request while its initial batch is fresh") { !preparationResponse.traffic.waiting.isEmpty }
        preparationResponse.date = preparationResponse.at(1031)
        preparationResponse.traffic.release(); await until { !preparationResponse.watch.checking }
        expect(!preparationResponse.watch.stale && preparationResponse.watch.plan == beforePreparationRequest,
               "a fresh delayed response cannot accept a departure that now leaves too little preparation time")

        let proposalRetry = EveningFixture(); defer { proposalRetry.clean() }
        await proposalRetry.start()
        let replacementThreshold = proposalRetry.at(1060)
        proposalRetry.traffic.duration = { $0 < replacementThreshold ? 60 * 60 : 20 * 60 }
        proposalRetry.alerts.failing = true
        proposalRetry.date = proposalRetry.at(1028); proposalRetry.watch.refresh()
        await until { !proposalRetry.watch.checking && proposalRetry.watch.alertError != nil }
        let frozenReplacement = proposalRetry.watch.proposal!
        let requestCount = proposalRetry.traffic.requests.count
        let permissionReads = proposalRetry.alerts.calls.count
        proposalRetry.alerts.failing = false
        proposalRetry.advance(1029.1)
        await until("A frozen replacement proposal suppressed the failed risk-alert retry") { !proposalRetry.alerts.deliveries.isEmpty }
        expect(proposalRetry.alerts.deliveries.count == 1 && proposalRetry.watch.alertError == nil,
               "failed risk alert retries while a replacement proposal is awaiting a decision")
        await until { proposalRetry.alerts.calls.count > permissionReads }
        expect(proposalRetry.alerts.calls.last == false, "frozen replacement still refreshes notification permission passively")
        proposalRetry.advance(1031.1)
        expect(proposalRetry.watch.proposal == frozenReplacement && proposalRetry.traffic.requests.count == requestCount,
               "alert lifecycle work does not refresh or rewrite the frozen replacement proposal")
        expect(proposalRetry.alerts.deliveries.count == 1, "successful risk alert is not posted again on a later tick")

        let drivingChoice = EveningFixture(); defer { drivingChoice.clean() }
        drivingChoice.date = drivingChoice.at(1020)
        drivingChoice.watch.settings.homeBy = 1140
        let earlierSaving = drivingChoice.at(1040), shortestDrive = drivingChoice.at(1060)
        drivingChoice.traffic.duration = { $0 < earlierSaving ? 50 * 60 : $0 < shortestDrive ? 40 * 60 : 39 * 60 }
        drivingChoice.watch.begin(); await until { !drivingChoice.watch.checking }
        let initialDrivingOffer = drivingChoice.watch.proposal!
        expect(initialDrivingOffer.choice.departure == earlierSaving, "initial suggestion prefers earlier departure within two minutes of shortest drive")
        let earlyDrivingOffer = drivingChoice.watch.offer(for: initialDrivingOffer.baseline!, baseline: initialDrivingOffer.choice)!
        expect(drivingChoice.watch.acceptOffer(earlyDrivingOffer), "person can explicitly choose the earliest checked departure")
        expect(drivingChoice.watch.drivingAlternative?.departure == earlierSaving,
               "less-driving comparison uses the same earlier-within-two-minutes choice as the initial suggestion")

        let notification = EveningFixture(); defer { notification.clean() }
        await notification.start(); notification.alerts.delayed = true
        notification.advance(1045); await until { notification.alerts.waiting != nil }
        notification.watch.finish(title: "Ended", message: "")
        notification.alerts.release(); try? await Task.sleep(nanoseconds: 20_000_000)
        expect(notification.alerts.posted.isEmpty, "late notification removed after stop")

        // Review 1 regressions: consent, session ownership, preparation already underway.
        let beforeConsent = EveningFixture(); defer { beforeConsent.clean() }
        beforeConsent.traffic.duration = { _ in 80 * 60 }
        beforeConsent.watch.begin(); await until { !beforeConsent.watch.checking }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(beforeConsent.alerts.deliveries.isEmpty, "no risk alert before accepting any departure")

        let replay = EveningFixture(); defer { replay.clean() }
        replay.watch.begin(); await until { !replay.watch.checking }
        let priorSessionOffer = replay.watch.proposal!
        replay.watch.finish(title: "", message: "")
        replay.watch.begin(); await until { !replay.watch.checking }
        expect(!replay.watch.acceptOffer(priorSessionOffer), "old session offer rejected even with equal timestamps and samples")

        let harmless = EveningFixture(); defer { harmless.clean() }
        harmless.watch.settings.latest = 1050
        await harmless.start(); harmless.advance(1048); await until { !harmless.watch.checking }
        let kept = harmless.watch.plan
        var harmlessEdit = harmless.watch.makeDraft(); harmlessEdit.value.homeBy += 5
        expect(harmless.watch.applyDraft(harmlessEdit) == nil, "safe arrival edit during existing preparation")
        await until { !harmless.watch.checking }
        expect(harmless.watch.plan == kept, "safe edit does not restart packing")

        // Review 2: a suspended submission must recheck real time on completion.
        let dueCompletion = EveningFixture(); defer { dueCompletion.clean() }
        await dueCompletion.start(); dueCompletion.alerts.delayed = true
        dueCompletion.advance(1049); await until { dueCompletion.alerts.waiting != nil && !dueCompletion.watch.checking }
        dueCompletion.date = dueCompletion.at(1051) // No tick: still-fresh batch, now a missed departure.
        dueCompletion.alerts.release(); try? await Task.sleep(nanoseconds: 20_000_000)
        expect(dueCompletion.alerts.posted.isEmpty, "late cue removed when the clock crossed the missed boundary without a tick")

        // Copy must describe permission, not invent delivery or enabled alerts.
        for (state, short, summary) in [
            (AlertAuthorization.unknown, "Alerts not set up", "Notification permission has not been requested."),
            (.denied, "Alerts off", "Notifications are off. Traffic estimates still work."),
            (.unavailable, "Alerts unavailable", "Notifications are unavailable for this build. Traffic estimates still work."),
            (.allowed, "Alerts allowed", "Notifications are allowed in macOS.")
        ] {
            let copy = EveningFixture(); defer { copy.clean() }
            copy.alerts.state = state
            copy.watch.updateAuthorization(request: false)
            await until { !copy.alerts.calls.isEmpty && copy.watch.alertAuthorization == state }
            expect(copy.watch.alertStatusLabel == short, "permission-specific short label")
            expect(copy.watch.alertSummary == summary, "permission-specific explanation")
            expect(!copy.watch.departureAcceptanceNote.contains("start alerts"), "acceptance does not promise alert availability")
        }
        let copy = EveningFixture(); defer { copy.clean() }
        await copy.start()
        copy.alerts.failing = true; copy.advance(1045)
        await until { copy.watch.alertError != nil }
        expect(copy.watch.alertStatusLabel == "Alert problem", "failed submission is distinct from denied permission")
        expect(copy.watch.alertSummary.contains("allowed, but"), "failure does not claim permission was revoked")
        copy.watch.setSleeping(true)
        expect(copy.watch.staleHeading == "Watching is paused", "sleep is not a network-failure heading")
        copy.watch.connectivityChanged(false)
        expect(copy.watch.staleHeading == "Watching is paused", "sleep takes priority when both conditions hold")
        copy.watch.setSleeping(false)
        expect(copy.watch.staleHeading == "No internet connection", "offline title identifies cause")
        expect(copy.watch.nextCheck == nil, "no next-check promise while offline")
        let overdue = EveningFixture(); defer { overdue.clean() }
        await overdue.start(); overdue.advance(1051)
        expect(overdue.watch.nextCheck == nil, "missed departure does not promise automatic recheck")
        expect(overdue.watch.usualSettingsNotice == nil, "Settings does not repeat an unrelated departure notice")
        _ = overdue.watch.makeUsualTimes()
        expect(overdue.watch.usualSettingsNotice == "Usual times saved.", "explicit usual-setting action has feedback")

        print("PASS: \(checks) evening controller checks; fake traffic/alerts, no native UI or delivery exercised")
    }
}
