import Foundation
#if !WINDOW_PORTABLE_TESTS
import Combine
#endif
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

#if !WINDOW_CORE_TESTS
@main
#endif
struct TarasLiveTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    @MainActor static func settle(_ condition: () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for traffic")
    }
    @MainActor static func main() async throws {
        let f = LiveFixture(); defer { f.clean() }
        let w = f.watch!
        var empty = w.settings; empty.origin = nil; empty.destination = nil; w.settings = empty
        expect(w.tarasPresentation.snapshot.capsule == "SET ROUTE", "new sandbox starts with route setup")
        empty.origin = SavedPlace(name: "Office", address: "Office", latitude: 37, longitude: -122)
        empty.destination = SavedPlace(name: "Home", address: "Home", latitude: 38, longitude: -122)
        w.settings = empty
        expect(w.tarasPresentation.snapshot.capsule == "CHECK TIMES", "accepted route is ready")
        expect(w.tarasPresentation.snapshot.headerRight == "READY FOR TODAY", "ready header")
        expect(w.tarasPresentation.snapshot.rows[0].label.hasPrefix("WINDOW ") && !w.tarasPresentation.snapshot.rows[0].label.contains("SET A ROUTE"), "ready Leave row shows saved window")
        let invalid = LiveFixture(); defer { invalid.clean() }
        invalid.watch.settings.packing = -1
        expect(invalid.watch.tarasPresentation.snapshot.headerRight == "EDIT JOURNEY TIMES", "invalid saved times safely open editor")
        expect(invalid.watch.tarasPresentation.snapshot.model == nil, "invalid times fabricate no traffic")
        expect(invalid.watch.tarasPresentation.snapshot.capsule == "EDIT TIMES", "invalid times with route invite an edit")
        expect(invalid.watch.tarasPresentation.snapshot.headerLeft != "NO ROUTE YET", "invalid times keep configured route")
        var feedback = TarasFeedbackState()
        for label in ["+5M DOESN'T FIT", "CHOICE NEEDS RECHECK", "NO DEPARTURE FITS"] {
            let time = f.date
            expect(feedback.update(label, at: time) == label, "feedback initially visible")
            expect(feedback.update(label, at: time.addingTimeInterval(2.99)) == label, "feedback keeps full hold")
            expect(feedback.update(label, at: time.addingTimeInterval(3)) == nil, "feedback expires after three seconds")
            expect(feedback.update(label, at: time.addingTimeInterval(20)) == nil, "clock ticks never restart feedback")
            _ = feedback.update(nil, at: time.addingTimeInterval(21))
        }
        var publications: [TarasRulerModel.PanelSnapshot] = []
        #if WINDOW_PORTABLE_TESTS
        PortablePublications.willChange = { publications.append(w.tarasPresentation.snapshot) }
        #else
        let observation = w.objectWillChange.sink { publications.append(w.tarasPresentation.snapshot) }
        #endif
        f.traffic.blocked = true
        w.begin()
        expect(w.tarasPresentation.snapshot.state == .checking, "real checking state")
        expect(w.tarasPresentation.snapshot.capsuleDisabled, "checking cannot commit")
        expect(w.tarasPresentation.snapshot.expectedCount > 0, "real candidate count")
        await settle { f.traffic.waiting.count == 2 }
        let firstChunk = f.traffic.waiting
        f.traffic.waiting = []
        for (departure, continuation) in firstChunk {
            continuation.resume(returning: DepartureEstimate(departure: departure, driving: f.traffic.seconds(departure)))
        }
        await settle { w.checkingSamples.count == 2 }
        expect(w.tarasPresentation.snapshot.receivedCount == 2, "progress counts actual returned samples")
        expect(w.tarasPresentation.snapshot.bars.count == 2, "only returned bars shown")
        expect(w.proposal == nil, "partial traffic cannot suggest a departure")
        f.traffic.release()
        await settle { !w.checking && w.proposal != nil }
        let suggested = w.tarasPresentation
        expect(suggested.snapshot.earlierDeparture == w.proposal?.baseline?.departure,
               "the earliest feasible offer is available without using the ruler")
        expect(suggested.snapshot.earlierDeparture != w.proposal?.choice.departure,
               "the earlier offer does not duplicate the recommendation")
        expect(try w.tarasPlanSnapshot().suggestedDeparture == suggested.snapshot.preferredDeparture?.departure,
               "widget shares the panel suggestion")
        let overtime = LiveFixture(); defer { overtime.clean() }
        let lighterTrafficFrom = overtime.at(1050)
        overtime.traffic.seconds = { $0 < lighterTrafficFrom ? 2460 : 1860 }
        overtime.watch.begin()
        await settle { !overtime.watch.checking && overtime.watch.proposal != nil }
        let overtimeSnapshot = overtime.watch.tarasPresentation.snapshot
        let lessDriving = overtime.watch.proposal?.choice.departure
        expect(lessDriving != nil && overtimeSnapshot.preferredDeparture?.departure == lessDriving,
               "the panel leads with the less-driving suggestion inside the limits")
        expect(overtimeSnapshot.earlierDeparture == overtime.at(1030), "the earlier departure stays available")
        expect(try overtime.watch.tarasPlanSnapshot().suggestedDeparture == lessDriving, "widget agrees with the panel's suggestion")
        publications.append(suggested.snapshot)
        #if WINDOW_PORTABLE_TESTS
        PortablePublications.willChange = nil
        #else
        observation.cancel()
        #endif
        // Replay every pre-mutation publish, including final samples, batch, checking=false and proposal.
        expect(publications.contains { $0.state == .checking && $0.receivedCount == $0.expectedCount && $0.expectedCount > 0 },
               "recorded actual LiveWatch completion progress")
        expect(publications.contains { $0.state == .noFit && !$0.isChecking && $0.model != nil },
               "recorded checking=false before proposal publishes")
        let checkingPublish = publications.firstIndex { $0.state == .checking }!
        let completedPublish = publications[checkingPublish...].firstIndex { !$0.isChecking && $0.model != nil }!
        expect(!publications[completedPublish...].contains { $0.state == .checking },
               "LiveWatch completion publishes do not themselves reverse to checking")
        var landing = TarasLandingState()
        var previous: TarasRulerModel.PanelSnapshot?
        var staged: TarasRulerModel.PanelSnapshot?
        var visibleStates: [TarasRulerModel.State] = []
        var starts = 0
        for next in publications {
            // Render precedes onChange in SwiftUI.
            visibleStates.append(landing.content(incoming: next, previous: previous, staged: staged).state)
            let cause = PanelChange.classify(previous: previous, next: next)
            let holding = landing.receive(cause)
            if cause == .batchSettled && !holding { starts += 1; staged = previous }
            else if !holding { staged = nil }
            visibleStates.append(landing.content(incoming: next, previous: next, staged: staged).state)
            previous = next
        }
        expect(starts == 1, "one LiveWatch batch schedules exactly one settle")
        landing.finish(); staged = nil
        for _ in 0..<3 {
            let next = suggested.snapshot
            visibleStates.append(landing.content(incoming: next, previous: previous, staged: staged).state)
            _ = landing.receive(PanelChange.classify(previous: previous, next: next))
            previous = next
        }
        let firstChecking = visibleStates.firstIndex(of: .checking)!
        let firstValues = visibleStates[firstChecking...].firstIndex { $0 == .suggested || $0 == .noFit }!
        expect(!visibleStates[firstValues...].contains(.checking), "panel never reverses to checking after landed values first render")
        expect(visibleStates.last == .suggested, "settle finishes on actual suggestion")
        expect(suggested.snapshot.state == .suggested, "real suggestion")
        expect(suggested.snapshot.model?.suggestion == w.proposal?.choice, "suggestion uses policy sample")
        expect(suggested.menuTitle == suggested.snapshot.menuTitle, "menu uses panel time format")
        expect(!f.alerts.authorizationCalls.contains(true), "checking never requests permission")
        expect(w.acceptOffer(suggested.primaryOffer!), "rendered frozen offer accepts")
        await settle { f.alerts.authorizationCalls.contains(true) }
        expect(w.tarasPresentation.snapshot.state == .watching, "committed state")
        expect(w.tarasPresentation.snapshot.committedDeparture == w.plan?.departure, "committed time preserved")
        expect(w.tarasPresentation.snapshot.circleDisabled == !w.canDelay, "plus follows canDelay")
        expect(w.tarasPresentation.offers[w.plan!.departure] == nil, "commitment is never offered again")
        expect(w.tarasPresentation.offers.isEmpty, "all watching scrub samples are preview-only")
        f.advance(to: 1045); await settle { !w.checking }
        expect(w.tarasPresentation.snapshot.rows[1].status == "WRAP UP NOW", "wrapping phase")
        f.advance(to: 1050); await settle { !w.checking }
        expect(w.tarasPresentation.snapshot.rows[0].status == "LEAVE NOW", "due phase")
        expect(w.tarasPresentation.snapshot.circleDisabled, "approved due-phase plus is disabled")
        f.advance(to: 1051)
        expect(w.tarasPresentation.snapshot.rows[0].status == "PASSED", "missed phase")
        expect(w.tarasPresentation.snapshot.capsule == "CHECK AGAIN", "missed requires recheck")
        expect(w.tarasPresentation.snapshot.circleSymbol == nil, "missed plan uses one recheck action")
        w.setSleeping(true)
        expect(w.tarasPresentation.snapshot.headerRight == "PAUSED · MAC ASLEEP", "sleep pause state")
        w.connectivityChanged(false)
        w.setSleeping(false)
        expect(w.tarasPresentation.snapshot.state == .paused, "offline pauses")
        expect(w.tarasPresentation.snapshot.rows.allSatisfy(\.valDim), "paused numbers dim")
        expect(w.tarasPresentation.snapshot.capsuleDisabled, "offline cannot recheck")
        expect(w.tarasPresentation.snapshot.acceptableDepartures?.isEmpty == true, "paused scrubs cannot accept")

        let undo = LiveFixture(); defer { undo.clean() }
        await undo.start()
        let watched = undo.watch.plan?.departure
        expect(watched != nil && undo.watch.active, "undo fixture is watching")
        undo.watch.stopWatching()
        let stopped = undo.watch.tarasPresentation.snapshot
        expect(!undo.watch.active && undo.watch.canUndoStop, "stop is immediate and undoable")
        expect(stopped.capsule == "UNDO" && stopped.headerRight == "WATCH STOPPED" && !stopped.capsuleDisabled,
               "the panel offers Undo right after stopping")
        expect(stopped.endAnnouncement == "Stopped watching. Choose Undo to keep watching.", "VoiceOver hears the Undo offer")
        expect(undo.watch.undoStop() && undo.watch.active, "undo restarts the watch")
        await settle { !undo.watch.checking && undo.watch.plan != nil }
        expect(undo.watch.plan?.departure == watched && undo.watch.proposal == nil,
               "undo keeps the stopped departure when the fresh check still offers it")
        expect(!undo.watch.canUndoStop && undo.watch.tarasPresentation.snapshot.capsule != "UNDO", "undo is spent once used")
        undo.watch.stopWatching()
        undo.date = undo.date.addingTimeInterval(LiveWatch.undoStopSeconds); undo.watch.tick()
        expect(!undo.watch.canUndoStop && undo.watch.tarasPresentation.snapshot.capsule != "UNDO", "the Undo offer ends after a few seconds")
        expect(!undo.watch.undoStop() && !undo.watch.active, "a late undo does nothing")
        undo.watch.begin(); await settle { !undo.watch.checking }
        undo.watch.finish(title: "You’re on your way", message: "Departure alerts have stopped.")
        expect(!undo.watch.canUndoStop, "leaving is not an undoable stop")

        let pausedAlerts = LiveFixture(); defer { pausedAlerts.clean() }
        await pausedAlerts.start()
        pausedAlerts.watch.connectivityChanged(false)
        let pausedRows = pausedAlerts.watch.tarasPresentation.snapshot
        expect(pausedRows.state == .paused && pausedRows.rows[1].status == "ALERTS OFF", "a paused watch shows its alerts are off")
        pausedAlerts.alerts.state = .denied; pausedAlerts.watch.updateAuthorization(request: false)
        await settle { pausedAlerts.watch.alertAuthorization == .denied }
        expect(pausedAlerts.watch.tarasPresentation.snapshot.alertsOff, "denied macOS alerts reach paused rows")

        let stale = LiveFixture(); defer { stale.clean() }
        stale.watch.begin(); await settle { !stale.watch.checking }
        let frozen = stale.watch.tarasPresentation.primaryOffer!
        stale.date = stale.date.addingTimeInterval(301); stale.watch.tick()
        expect(stale.watch.tarasPresentation.snapshot.state == .stale, "five-minute expiry")
        expect(!stale.watch.acceptOffer(frozen), "expired rendered offer rejected")
        expect(stale.watch.tarasPresentation.snapshot.capsule == "CHECK AGAIN", "expired USE removed")
        expect(stale.watch.tarasPresentation.snapshot.headerRight == "CHOICE NEEDS RECHECK", "rejected frozen offer has visible reason")
        stale.traffic.blocked = true
        _ = stale.watch.recheck(replan: false)
        expect(stale.watch.tarasPresentation.snapshot.state == .checking, "running recheck wins over expired batch")
        stale.traffic.release(); await settle { !stale.watch.checking }

        let refreshed = LiveFixture(); defer { refreshed.clean() }
        refreshed.watch.begin(); await settle { !refreshed.watch.checking }
        let replacedOffer = refreshed.watch.tarasPresentation.primaryOffer!
        refreshed.date = refreshed.date.addingTimeInterval(60); refreshed.watch.tick()
        _ = refreshed.watch.recheck(replan: false); await settle { !refreshed.watch.checking }
        expect(!refreshed.watch.acceptOffer(replacedOffer), "refreshed batch rejects a still-fresh frozen offer")
        expect(refreshed.watch.tarasPresentation.snapshot.headerRight == "CHOICE NEEDS RECHECK", "refreshed frozen offer rejection is visible")
        let newPresentation = refreshed.watch.tarasPresentation
        let newSample = newPresentation.snapshot.model!.suggestion
        expect(!newPresentation.snapshot.canUseSample(newSample, previewedIn: suggested.snapshot), "new batch cannot enable an old frozen offer")

        let delay = LiveFixture(); defer { delay.clean() }
        delay.traffic.seconds = { _ in 1800 }
        await delay.start()
        let beforeDelay = delay.watch.plan!.departure
        delay.traffic.blocked = true
        delay.watch.delay()
        expect(delay.watch.tarasPresentation.snapshot.headerRight.hasPrefix("CHECKING "), "delay exposes requested check")
        expect(delay.watch.tarasPresentation.snapshot.headerRight == "CHECKING " + TarasRulerModel.time(beforeDelay.addingTimeInterval(300), calendar: .current), "delay uses same 24-hour format as rows")
        let pendingDelay = delay.watch.tarasPresentation.snapshot
        let beforePendingDelay = pendingDelay.replacingFeedbackLabel(nil)
        expect(PanelChange.classify(previous: beforePendingDelay, next: pendingDelay) == .feedback, "pending delay dots never masquerade as a phase flip")
        delay.traffic.release(); await settle { !delay.watch.checking }
        expect(delay.watch.plan?.departure == beforeDelay.addingTimeInterval(300), "accepted +5 displays new commitment")
        expect(delay.watch.tarasPresentation.snapshot.model?.suggestion.departure == delay.watch.plan?.departure, "accepted delay updates panel time")
        expect(PanelChange.classify(previous: pendingDelay, next: delay.watch.tarasPresentation.snapshot) == .delayLanded, "confirmed changed commitment remains a delay landing")
        let kept = delay.watch.plan!.departure
        delay.traffic.seconds = { date in date == kept ? 1800 : 7200 }
        delay.watch.delay(); await settle { !delay.watch.checking }
        expect(delay.watch.plan?.departure == kept, "core rejects +5 that breaks home-by and retains plan")
        expect(delay.watch.message == "That departure does not fit. Your previous plan is unchanged.", "rejection is core policy result")
        expect(delay.watch.tarasPresentation.snapshot.headerRight == "+5M DOESN'T FIT", "rejected +5 has visible reason")
        let failedDelay = delay.watch.tarasPresentation.snapshot
        let checkingFailure = TarasRulerModel.PanelSnapshot(state: .watching, limits: failedDelay.limits,
            now: failedDelay.now, model: failedDelay.model, committedDeparture: failedDelay.committedDeparture,
            isChecking: true, feedbackLabel: "CHECKING 17:35")
        expect(PanelChange.classify(previous: checkingFailure, next: failedDelay) == .feedback, "rejected delay announces feedback instead of a dot phase flip")
        let beforeWrap = TarasRulerModel.PanelSnapshot(state: .watching, limits: failedDelay.limits,
            now: kept.addingTimeInterval(-failedDelay.limits.packing - 1), model: failedDelay.model, committedDeparture: kept)
        let atWrap = TarasRulerModel.PanelSnapshot(state: .watching, limits: failedDelay.limits,
            now: kept.addingTimeInterval(-failedDelay.limits.packing), model: failedDelay.model, committedDeparture: kept)
        expect(PanelChange.classify(previous: beforeWrap, next: atWrap) == .phase, "actual wrap-up boundary has a phase cause")
        expect(PanelChange.classify(previous: failedDelay, next: failedDelay.replacingFeedbackLabel(nil)) == .feedback, "feedback expiry restores header without phase news")

        let retained = LiveFixture(); defer { retained.clean() }
        await retained.start()
        let evidence = retained.watch.tarasPresentation.snapshot
        retained.watch.pause("Couldn’t refresh traffic estimates. Try again.")
        retained.traffic.blocked = true
        expect(retained.watch.recheck(), "paused retained commitment can retry")
        let retry = retained.watch.tarasPresentation.snapshot
        expect(retry.state == .checking && retry.checkingKeepsEvidence, "retained-plan retry uses evidence checking state")
        expect(retry.headerRight == "CHECKING 0/\(retry.expectedCount)", "retained retry displays real count")
        expect(retry.rows.map(\.value) == evidence.rows.map(\.value), "retry keeps all committed numbers")
        expect(retry.rows.allSatisfy(\.valDim), "retained evidence dims during checking")
        expect(retry.bars.allSatisfy { $0.opacity == 0.3 }, "old checking bars dim to thirty percent")
        expect(retry.capsuleDisabled, "retained checking cannot use or recheck twice")
        await settle { retained.traffic.waiting.count == 2 }
        let retryChunk = retained.traffic.waiting
        retained.traffic.waiting = []
        for (departure, continuation) in retryChunk {
            continuation.resume(returning: DepartureEstimate(departure: departure, driving: retained.traffic.seconds(departure)))
        }
        await settle { retained.watch.checkingSamples.count == 2 }
        let progressing = retained.watch.tarasPresentation.snapshot
        expect(progressing.headerRight == "CHECKING 2/\(progressing.expectedCount)", "retained retry count advances")
        expect(progressing.bars.filter { $0.opacity == 0.6 }.allSatisfy { $0.height == 20 }, "arrivals are uniform twenty-point markers")
        retained.traffic.release(); await settle { !retained.watch.checking }
        expect(retained.watch.tarasPresentation.snapshot.state == .watching, "successful retry returns to retained commitment")
        retained.traffic.blocked = true
        retained.date = retained.date.addingTimeInterval(301)
        retained.watch.tick()
        let expiredRetry = retained.watch.tarasPresentation.snapshot
        expect(expiredRetry.state == .checking && expiredRetry.checkingKeepsEvidence, "expired retained plan uses evidence checking on automatic retry")
        expect(expiredRetry.rows.map(\.value) == evidence.rows.map(\.value), "expired retained plan keeps old row values")
        retained.traffic.release(); await settle { !retained.watch.checking }
        expect(PanelChange.classify(previous: nil, next: evidence) == .opened, "first presentation is a hard-cut open")
        expect(PanelChange.classify(previous: evidence, next: retry) == .checkingStarted, "retry has an explicit motion cause")
        expect(PanelChange.classify(previous: retry, next: progressing) == .checkingProgress, "real progress has an arrival cause")
        expect(PanelChange.classify(previous: progressing, next: evidence) == .batchSettled, "completed retry uses settle choreography")
        let pausedRetry = TarasRulerModel.PanelSnapshot(state: .paused, limits: retry.limits, now: retry.now, model: retry.model)
        expect(PanelChange.classify(previous: progressing, next: pausedRetry) == .paused, "failed retry dims without a successful settle")

        delay.watch.finish(title: "Stopped", message: "")
        expect(delay.watch.tarasPresentation.snapshot.headerRight != "TRAFFIC CHANGED", "old action feedback does not survive stopping")
        expect(delay.watch.tarasPresentation.snapshot.endAnnouncement == nil, "explicit stop uses the panel stop announcement")
        retained.date = retained.at(1062); retained.watch.tick()
        let expiredPresentation = retained.watch.tarasPresentation.snapshot
        expect(expiredPresentation.endAnnouncement == retained.watch.endMessage && expiredPresentation.endAnnouncement?.isEmpty == false, "expiry exposes exact core announcement")
        expect(expiredPresentation.replacingFeedbackLabel(nil).endAnnouncement == expiredPresentation.endAnnouncement, "feedback filtering preserves expiry announcement")

        let risk = LiveFixture(); defer { risk.clean() }
        risk.traffic.seconds = { _ in 7200 }
        risk.watch.begin(); await settle { !risk.watch.checking }
        let recovery = risk.watch.tarasPresentation
        expect(recovery.snapshot.state == .noFit, "no feasible departure")
        expect(recovery.snapshot.capsule.contains("LATE"), "recovery names lateness")
        let saved = risk.watch.settings
        expect(recovery.primaryOffer?.recovery == true, "recovery carries explicit exception")
        expect(risk.watch.acceptOffer(recovery.primaryOffer!), "frozen recovery accepts")
        expect(risk.watch.settings == saved, "recovery never edits stored schedule")
        expect(risk.watch.limits != saved.limits(on: risk.date), "only active limits relax")
        expect(risk.watch.tarasPresentation.snapshot.rows.last?.status.hasPrefix("LATE ") == true,
               "the accepted plan still reports lateness against the original arrival deadline")
        risk.watch.finish(title: "Stopped", message: "")
        expect(try risk.watch.tarasPlanSnapshot().state == .idle, "stop clears widget plan")
        expect(!risk.watch.acceptOffer(recovery.primaryOffer!), "old-session recovery cannot replay")

        let failed = LiveFixture(); defer { failed.clean() }
        failed.watch.begin()
        failed.watch.pause("Test failure")
        expect(failed.watch.tarasPresentation.snapshot.state == .paused, "first-request failure has a panel state")
        expect(failed.watch.tarasPresentation.snapshot.rows.count == 4, "failure without evidence retains all four rows")
        expect(failed.watch.tarasPresentation.snapshot.rows[0].label == "NO CHECKED DEPARTURE", "no evidence is never invented")
        failed.traffic.blocked = true
        _ = failed.watch.recheck(replan: false)
        expect(failed.watch.tarasPresentation.snapshot.state == .checking, "running recheck wins over pauseReason")
        failed.traffic.release(); await settle { !failed.watch.checking }

        let partial = LiveFixture(); defer { partial.clean() }
        await partial.start()
        let chosenDeparture = partial.watch.plan!.departure
        partial.date = chosenDeparture.addingTimeInterval(-partial.watch.limits!.packing)
        partial.traffic.fails = { $0 != chosenDeparture }
        partial.watch.refresh()
        await settle { !partial.watch.checking }
        expect(partial.watch.plan?.departure == chosenDeparture && !partial.watch.stale,
               "a failed alternative cannot erase a successful ETA for the committed departure")
        await settle { !partial.alerts.posted.isEmpty }
        partial.traffic.fails = { $0 == chosenDeparture }
        partial.alerts.failuresRemaining = 1
        partial.watch.refresh()
        await settle { !partial.watch.checking && partial.watch.alertError != nil }
        partial.date = partial.date.addingTimeInterval(60)
        partial.watch.tick()
        await settle { partial.alerts.posted.contains { $0.hasSuffix(".unconfirmed") } }
        expect(partial.watch.stale && partial.alerts.posted.allSatisfy { $0.hasSuffix(".unconfirmed") },
               "failure sends a review warning instead of a stale departure cue")
        let firstNotice = partial.alerts.posted
        partial.watch.refresh()
        await settle { !partial.watch.checking }
        expect(partial.alerts.posted == firstNotice, "a retry failure preserves the unconfirmed-plan notice")

        let planless = LiveFixture(); defer { planless.clean() }
        await planless.start()
        planless.traffic.seconds = { _ in 90 * 60 }
        planless.watch.refresh()
        await settle { !planless.watch.checking && planless.alerts.posted.contains { $0.hasSuffix(".risk") } }
        expect(planless.watch.plan == nil, "fresh evidence withdrew the accepted departure")
        planless.traffic.fails = { _ in true }
        planless.watch.refresh()
        await settle { !planless.watch.checking && planless.alerts.posted.contains { $0.hasSuffix(".unconfirmed") } }
        expect(planless.watch.stale && planless.alerts.posted.allSatisfy { $0.hasSuffix(".unconfirmed") },
               "a failed recheck keeps a review notice even after the accepted departure was withdrawn")

        let wrapping = LiveFixture(); defer { wrapping.clean() }
        await wrapping.start()
        let originalDeparture = wrapping.watch.plan!.departure
        wrapping.date = originalDeparture.addingTimeInterval(-60)
        wrapping.traffic.seconds = { $0 == originalDeparture ? 90 * 60 : 25 * 60 }
        wrapping.watch.refresh()
        await settle { !wrapping.watch.checking }
        expect(wrapping.watch.proposal?.choice.departure == originalDeparture.addingTimeInterval(300),
               "an underway wrap-up preserves the earliest feasible replacement after traffic changes")

        let insufficient = LiveFixture(); defer { insufficient.clean() }
        await insufficient.start()
        let insufficientDeparture = insufficient.watch.plan!.departure
        insufficient.traffic.fails = { $0 != insufficientDeparture }
        insufficient.traffic.seconds = { _ in 80 * 60 }
        insufficient.watch.refresh()
        await settle { !insufficient.watch.checking }
        expect(insufficient.watch.stale && insufficient.watch.recoveryOptions == nil,
               "a single unusable ETA cannot justify relaxing limits when alternatives failed")

        let due = LiveFixture(); defer { due.clean() }
        due.watch.settings.packing = 0
        await due.start()
        let dueDeparture = due.watch.plan!.departure
        due.date = dueDeparture.addingTimeInterval(-10)
        due.traffic.seconds = { _ in 70 * 60 }
        due.traffic.blocked = true
        due.watch.refresh()
        await settle { due.traffic.waiting.count == 2 }
        due.date = dueDeparture.addingTimeInterval(5)
        due.traffic.release()
        await settle { !due.watch.checking }
        expect(due.watch.plan == nil && due.watch.tarasPresentation.snapshot.menuTitle != " Leave now",
               "fresh evidence invalidates a missed deadline even if a check lands in the departure minute")
        expect(try due.watch.tarasPlanSnapshot().state != .watching, "widget cannot retain an invalid commitment")
        await settle { !due.alerts.posted.isEmpty }
        expect(due.alerts.posted.allSatisfy { $0.hasSuffix(".risk") }, "a broken deadline can send only a review alert")

        let late = LiveFixture(); defer { late.clean() }
        await late.start()
        let lateDeparture = late.watch.plan!.departure
        late.date = lateDeparture.addingTimeInterval(-10)
        late.traffic.blocked = true
        late.traffic.seconds = { _ in 80 * 60 }
        late.watch.refresh()
        await settle { late.traffic.waiting.count == 2 }
        late.date = lateDeparture.addingTimeInterval(61)
        late.traffic.release()
        await settle { !late.watch.checking }
        let lastRequestCount = late.traffic.requests
        late.watch.tick()
        expect(late.watch.missed && late.traffic.requests == lastRequestCount && !late.watch.checking,
               "a refresh that completes after the grace period cannot restart a missed watch")

        let edited = LiveFixture(); defer { edited.clean() }
        await edited.start()
        let originalCheck = edited.watch.batch!.checkedAt
        edited.date = edited.date.addingTimeInterval(15 * 60)
        edited.traffic.blocked = true
        var editedJourney = edited.watch.makeDraft()
        editedJourney.value.homeBy += 1
        expect(edited.watch.applyDraft(editedJourney) == nil, "edit preserves feasible time")
        let duringEdit = try edited.watch.tarasPlanSnapshot()
        expect(duringEdit.state == .paused && duringEdit.checkedAt == originalCheck,
               "editing a limit keeps the estimate's actual age while a replacement is pending")
        edited.traffic.release(); await settle { !edited.watch.checking }

        let scoped = LiveFixture(); defer { scoped.clean() }
        let usualBefore = scoped.watch.store.load()
        var longWindow = scoped.watch.makeDraft()
        longWindow.value.earliest = 8 * 60
        expect(scoped.watch.draftError(longWindow) == nil, "the remainder of today's long window can be used")
        expect(scoped.watch.applyDraft(longWindow, saveForFutureDays: true) != nil, "the full long window cannot become usual")
        expect(scoped.watch.store.load() == usualBefore, "an invalid usual save changes no stored schedule")
        var onlyToday = scoped.watch.makeDraft()
        onlyToday.value.packing = 3
        expect(scoped.watch.applyDraft(onlyToday) == nil, "today-only save succeeds")
        expect(scoped.watch.store.load() == usualBefore, "today-only save leaves the usual journey alone")
        var usual = scoped.watch.makeDraft()
        usual.value.destination = SavedPlace(name: "Library", address: "Example library", latitude: 39, longitude: -122)
        usual.value.homeBy += 10
        expect(scoped.watch.applyDraft(usual, saveForFutureDays: true) == nil, "one save applies the draft today and in the future")
        expect(scoped.watch.store.load().sameJourney(as: usual.value), "usual save persists both endpoints and times")
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: scoped.date)!
        expect(scoped.watch.store.loadToday(on: nextDay).sameJourney(as: usual.value), "the next day loads the saved journey")
        var staleDraft = scoped.watch.makeDraft()
        staleDraft.value.packing = 12
        scoped.date = nextDay
        expect(scoped.watch.applyDraft(staleDraft, saveForFutureDays: true) != nil, "yesterday's draft cannot become the usual journey")
        expect(scoped.watch.store.load().sameJourney(as: usual.value), "rejected draft leaves usual settings intact")

        let refreshingAlerts = LiveFixture(); defer { refreshingAlerts.clean() }
        await refreshingAlerts.start()
        await settle { !refreshingAlerts.watch.requestingAlertPermission }
        refreshingAlerts.alerts.delayAuthorization = true
        refreshingAlerts.alerts.state = .denied
        refreshingAlerts.watch.updateAuthorization(request: false)
        await settle { refreshingAlerts.alerts.authorizationWaiting != nil }
        expect(refreshingAlerts.watch.tarasPresentation.snapshot.alertStatus == "Checking alerts", "a permission refresh does not report cached permission")
        refreshingAlerts.alerts.releaseAuthorization()
        await settle { !refreshingAlerts.watch.requestingAlertPermission }
        expect(refreshingAlerts.watch.tarasPresentation.snapshot.alertStatus == "Alerts off", "revoked permission is visible")

        let failedAlert = LiveFixture(); defer { failedAlert.clean() }
        await failedAlert.start()
        await settle { !failedAlert.watch.requestingAlertPermission }
        failedAlert.alerts.failuresRemaining = 1
        failedAlert.advance(to: 1045)
        await settle { failedAlert.watch.alertError != nil }
        let deliveryError = failedAlert.watch.alertError
        for authorization in [AlertAuthorization.unavailable, .allowed] {
            failedAlert.alerts.state = authorization
            failedAlert.watch.updateAuthorization(request: false)
            await settle { !failedAlert.watch.requestingAlertPermission }
        }
        expect(failedAlert.watch.alertError == deliveryError, "permission recovery does not clear a failed submission")

        let zero = LiveFixture(); defer { zero.clean() }
        zero.watch.settings.packing = 0; await zero.start()
        expect(zero.watch.tarasPresentation.snapshot.rows[1].status == "NOT NEEDED", "zero packing")
        expect(zero.watch.tarasPresentation.snapshot.rows[1].value == "—", "zero packing has no fake time")

        let defaults = UserDefaults(suiteName: "wp6-snapshot-\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: PlanSnapshotStore.key) }
        let original = try zero.watch.tarasPlanSnapshot()
        expect(try TarasSnapshotWriter.write(original, now: zero.date, to: defaults), "first widget write")
        expect(try !TarasSnapshotWriter.write(original, now: zero.date.addingTimeInterval(1), to: defaults), "clock tick skips write")
        let renewed = try PlanSnapshot(routeLabel: original.routeLabel, limits: original.limits, samples: original.samples,
            suggestedDeparture: original.suggestedDeparture, committedDeparture: original.committedDeparture,
            checkedAt: original.checkedAt.addingTimeInterval(180), state: original.state, alertStatus: original.alertStatus)
        expect(try !TarasSnapshotWriter.write(renewed, now: renewed.checkedAt, to: defaults), "unchanged three-minute refresh skips write")
        expect(try !TarasSnapshotWriter.write(renewed, now: original.expiresAt.addingTimeInterval(-61), to: defaults), "no early churn before renewal window")
        expect(try TarasSnapshotWriter.write(renewed, now: original.expiresAt.addingTimeInterval(-60), to: defaults), "renew one minute before published expiry")
        expect(PlanSnapshotStore.read(from: defaults)?.expiresAt == renewed.expiresAt, "renewal publishes newer evidence expiry")
        let paused = try PlanSnapshot(routeLabel: renewed.routeLabel, limits: renewed.limits, samples: renewed.samples,
            suggestedDeparture: renewed.suggestedDeparture, committedDeparture: renewed.committedDeparture,
            checkedAt: renewed.checkedAt, state: .paused, alertStatus: .denied)
        expect(try TarasSnapshotWriter.write(paused, now: renewed.checkedAt, to: defaults), "state/alerts changes write")
        expect(try !TarasSnapshotWriter.write(paused, now: renewed.checkedAt, to: defaults), "duplicate paused write skips")
        let changedSample = DepartureEstimate(departure: renewed.samples[0].departure, driving: renewed.samples[0].driving + 60)
        var samples = renewed.samples; samples[0] = changedSample
        let changed = try PlanSnapshot(routeLabel: "New route", limits: renewed.limits, samples: samples,
            suggestedDeparture: renewed.suggestedDeparture, committedDeparture: renewed.committedDeparture,
            checkedAt: renewed.checkedAt, state: renewed.state, alertStatus: renewed.alertStatus)
        expect(try TarasSnapshotWriter.write(changed, now: renewed.checkedAt, to: defaults), "route/numbers changes write immediately")
        expect(PlanSnapshotStore.read(from: defaults) == changed, "published numbers match controller")
        func jitter(_ driving: Double, departure: Date = changed.samples[0].departure, state: PlanSnapshot.State = .watching) throws -> PlanSnapshot {
            let sample = DepartureEstimate(departure: departure, driving: driving)
            return try PlanSnapshot(routeLabel: "Precision", limits: renewed.limits, samples: [sample],
                suggestedDeparture: departure, committedDeparture: departure, checkedAt: renewed.checkedAt,
                state: state, alertStatus: .allowed)
        }
        let precision = try jitter(1801)
        expect(try TarasSnapshotWriter.write(precision, now: renewed.checkedAt, to: defaults), "precision baseline")
        expect(try !TarasSnapshotWriter.write(jitter(1803), now: renewed.checkedAt, to: defaults), "second-level Maps jitter does not reload")
        expect(try TarasSnapshotWriter.write(jitter(1831), now: renewed.checkedAt, to: defaults), "rounded arrival and driving minute changes reload")
        expect(try !TarasSnapshotWriter.write(jitter(1861), now: renewed.checkedAt, to: defaults), "matching driving and arrival readings do not reload")
        expect(try TarasSnapshotWriter.write(jitter(1891), now: renewed.checkedAt, to: defaults), "changed displayed minutes reload")
        expect(try TarasSnapshotWriter.write(jitter(1861, departure: precision.samples[0].departure.addingTimeInterval(60)), now: renewed.checkedAt, to: defaults), "departure change reloads")
        expect(try TarasSnapshotWriter.write(jitter(1861, state: .paused), now: renewed.checkedAt, to: defaults), "state change reloads")
        expect(try TarasSnapshotWriter.write(precision, now: renewed.checkedAt, to: defaults), "phase/state restoration reloads")
        let edgeDeparture = renewed.limits.latest
        let edgeDriving = renewed.limits.homeBy.timeIntervalSince(edgeDeparture) - renewed.limits.buffer
        func edgeSnapshot(extraSeconds: Double) throws -> PlanSnapshot {
            let sample = DepartureEstimate(departure: edgeDeparture, driving: edgeDriving + extraSeconds)
            return try PlanSnapshot(routeLabel: "Arrival buffer", limits: precision.limits, samples: precision.samples + [sample],
                suggestedDeparture: precision.suggestedDeparture, committedDeparture: precision.committedDeparture,
                checkedAt: precision.checkedAt, state: .watching, alertStatus: .allowed)
        }
        let stillFits = try edgeSnapshot(extraSeconds: 0)
        let missesBuffer = try edgeSnapshot(extraSeconds: 1)
        expect(try TarasSnapshotWriter.write(stillFits, now: renewed.checkedAt, to: defaults), "arrival buffer baseline")
        expect(try TarasSnapshotWriter.write(missesBuffer, now: renewed.checkedAt, to: defaults),
               "widget reloads when an alternative stops fitting despite unchanged displayed times")
        print("PASS: \(checks) Taras live assertions.")
    }
}
