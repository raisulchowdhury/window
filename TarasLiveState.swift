import Foundation

/// Offers travel with the rendered numbers so a click never accepts a refreshed replacement.
public struct TarasLivePresentation {
    public let snapshot: TarasRulerModel.PanelSnapshot
    public let menuTitle: String
    public var change: PanelChange = .opened
    let primaryOffer: DepartureOffer?
    let offers: [Date: DepartureOffer]

    func replacing(snapshot: TarasRulerModel.PanelSnapshot, change: PanelChange) -> Self {
        Self(snapshot: snapshot, menuTitle: snapshot.menuTitle, change: change, primaryOffer: primaryOffer, offers: offers)
    }
}

/// Observe a message once; clock ticks must not restart its three-second hold.
public struct TarasFeedbackState {
    private var previous: String?
    private var expiresAt = Date.distantPast
    public init() {}

    public mutating func update(_ label: String?, at now: Date) -> String? {
        let transient = ["+5M DOESN'T FIT", "+5M CHECK FAILED", "CHOICE NEEDS RECHECK", "NO DEPARTURE FITS"].contains(label ?? "")
        if label != previous {
            previous = label
            expiresAt = now.addingTimeInterval(TarasMotion.feedbackHold)
        }
        return transient && now >= expiresAt ? nil : label
    }
}

extension LiveWatch {
    var tarasPresentation: TarasLivePresentation {
        tarasPresentation(showChecking: false)
    }

    func tarasPresentation(showChecking: Bool, previousEvidence: TarasRulerModel? = nil) -> TarasLivePresentation {
        let displayedRoute = active ? route ?? settings : settings
        let title = [displayedRoute.origin?.name, displayedRoute.destination?.name]
            .compactMap { $0 }.joined(separator: " → ")
        guard let displayedLimits = limits ?? settings.limits(on: now) else {
            let fallback = WatchLimits(earliest: now, latest: now, homeBy: now.addingTimeInterval(3600), packing: 0)
            return TarasLivePresentation(snapshot: .init(state: .noRoute, limits: fallback, now: now,
                routeTitle: title, readyForToday: displayedRoute.routeID != nil,
                feedbackLabel: "EDIT JOURNEY TIMES"), menuTitle: "", primaryOffer: nil, offers: [:])
        }
        let recovery = recoveryOptions?.primary
        let choice = plan ?? proposal?.choice ?? recovery
        let visibleCheck = checking && pendingDeparture == nil && (plan == nil || stale || showChecking)
        let keepsEvidence = visibleCheck && batch?.samples.isEmpty == false
        let displayBatch = visibleCheck && !keepsEvidence
            ? route?.routeID.map { TrafficBatch(routeID: $0, checkedAt: now, samples: checkingSamples) } : batch
        let selected = choice ?? displayBatch?.samples.first
        let model = keepsEvidence && previousEvidence?.batch.routeID == displayBatch?.routeID
            && previousEvidence?.limits == displayedLimits ? previousEvidence : displayBatch.flatMap { batch in selected.flatMap {
            TarasRulerModel(batch: batch, limits: displayedLimits, suggestedDeparture: $0.departure,
                            comparisonBaseline: proposal?.baseline, originalArrivalLimits: recoveryOriginalLimits)
        } }
        let state: TarasRulerModel.State
        if !active { state = .noRoute }
        else if visibleCheck { state = .checking }
        else if stale { state = !online || sleeping || pauseReason != nil ? .paused : .stale }
        else if plan != nil { state = .watching }
        else if let proposal, canAccept(proposal) { state = .suggested }
        else if proposal != nil { state = .stale }
        else { state = .noFit }
        var offers: [Date: DepartureOffer] = [:]
        if let batch, state == .suggested || state == .noFit {
            for sample in batch.samples {
                let isRecovery = state == .noFit
                if let offer = offer(for: sample, baseline: proposal?.baseline ?? plan, recovery: isRecovery), canAccept(offer) {
                    offers[sample.departure] = offer
                }
            }
        }
        let primaryOffer = proposal ?? recovery.flatMap { offers[$0.departure] }
        let primaryAvailable: Bool
        switch state {
        case .noRoute: primaryAvailable = true // Invalid saved times open the journey editor.
        case .checking: primaryAvailable = false
        case .suggested, .noFit: primaryAvailable = primaryOffer.map(canAccept) ?? canRecheck
        case .watching: primaryAvailable = missed ? canRecheck : true
        case .paused, .stale: primaryAvailable = canRecheck
        }
        let snapshot = TarasRulerModel.PanelSnapshot(state: state, limits: displayedLimits, now: now,
            model: model, routeTitle: title, committedDeparture: plan?.departure,
            expectedCount: checkingExpectedCount, receivedCount: checking ? checkingSamples.count : 0,
            isChecking: checking, checkingKeepsEvidence: keepsEvidence, checkingSamples: checking ? checkingSamples : [],
            readyForToday: displayedRoute.routeID != nil, acceptableDepartures: Set(offers.keys), offerSession: primaryOffer?.session,
            primaryAvailable: primaryAvailable, delayAvailable: canDelay && cuePhase != .leaveNow,
            recheckAvailable: canRecheck, preparationAlreadyUnderway: cuePhase == .wrappingUp,
            primaryIsRecheck: state == .noFit && primaryOffer == nil,
            pauseLabel: sleeping ? "PAUSED · MAC ASLEEP" : !online ? "PAUSED · NO CONNECTION"
                : pauseReason?.contains("refresh") == true || pauseReason?.contains("too long") == true ? "CHECK FAILED" : nil,
            feedbackLabel: !active && displayedRoute.routeID != nil && validation != nil ? "EDIT JOURNEY TIMES" : tarasFeedbackLabel,
            endAnnouncement: !active && (endTitle == "Watch expired" || endTitle == "Watch ended") ? endMessage
                : canUndoStop ? "Stopped watching. Choose Undo to keep watching." : nil,
            // Header and menu title read this only while watching; paused rows read it too.
            alertsOff: active && (alertAuthorization != .allowed || alertError != nil),
            alertStatus: tarasAlertStatus, undoStopAvailable: canUndoStop)
        return TarasLivePresentation(snapshot: snapshot, menuTitle: snapshot.menuTitle,
                                     primaryOffer: primaryOffer, offers: offers)
    }

    private var tarasAlertStatus: String {
        if requestingAlertPermission { return "Checking alerts" }
        if alertError != nil { return "Alerts unavailable" }
        switch alertAuthorization {
        case .allowed: return "Alerts allowed"
        case .unknown: return "Alerts not set"
        case .denied: return "Alerts off"
        case .unavailable: return "Alerts unavailable"
        }
    }

    private var tarasFeedbackLabel: String? {
        guard active, online, !sleeping else { return nil }
        if checking {
            return pendingDeparture.map { "CHECKING \(TarasRulerModel.time($0, calendar: .current))" }
        }
        switch message {
        case "That departure does not fit. Your previous plan is unchanged.",
             "That departure no longer fits your limits.": return "+5M DOESN'T FIT"
        case "Couldn’t check that departure. Your previous plan is unchanged.": return "+5M CHECK FAILED"
        case "Traffic no longer fits your limits.": return "NO DEPARTURE FITS"
        case "This choice needs a fresh check. Your saved limits are unchanged.": return "CHOICE NEEDS RECHECK"
        case "Traffic changed. Review a new departure.": return "TRAFFIC CHANGED"
        case "Some departure times could not be checked.": return "PARTIAL CHECK"
        default: return nil
        }
    }

    func tarasPlanSnapshot() throws -> PlanSnapshot {
        let presentation = tarasPresentation
        let state: PlanSnapshot.State
        if !active || batch?.samples.isEmpty != false { state = .idle }
        else if stale || presentation.snapshot.state == .stale || (plan == nil && proposal == nil) { state = .paused }
        else if plan != nil { state = .watching }
        else { state = .suggested }
        var samples = batch?.samples ?? []
        // A retained commitment may outlive a failed/late batch; keep its last checked numbers.
        if let plan, !samples.contains(where: { $0.departure == plan.departure }) { samples.append(plan) }
        let suggested = (state == .suggested ? presentation.snapshot.preferredDeparture?.departure : nil)
            ?? proposal?.choice.departure ?? plan?.departure ?? recoveryOptions?.primary.departure ?? samples.first?.departure
        let authorization: PlanSnapshot.AlertStatus
        if alertError != nil { authorization = .failed }
        else {
            switch alertAuthorization {
            case .unknown: authorization = .unknown
            case .allowed: authorization = .allowed
            case .denied: authorization = .denied
            case .unavailable: authorization = .unavailable
            }
        }
        return try PlanSnapshot(routeLabel: presentation.snapshot.routeTitle,
            limits: presentation.snapshot.limits, samples: state == .idle ? [] : samples,
            suggestedDeparture: state == .idle ? nil : suggested, committedDeparture: state == .idle ? nil : plan?.departure,
            checkedAt: batch?.checkedAt ?? now, state: state, alertStatus: authorization)
    }
}

/// Clock ticks and identical refreshes do not churn WidgetKit. Renew freshness at
/// a minute before expiry using newer evidence, so an unchanged plan stays usable.
public enum TarasSnapshotWriter {
    @discardableResult
    public static func write(_ snapshot: PlanSnapshot, now: Date, to defaults: UserDefaults) throws -> Bool {
        if let previous = PlanSnapshotStore.read(from: defaults),
           previous.routeLabel == snapshot.routeLabel, previous.limits == snapshot.limits,
           sameDisplayedSamples(previous.samples, snapshot.samples, limits: snapshot.limits),
           previous.suggestedDeparture == snapshot.suggestedDeparture,
           previous.committedDeparture == snapshot.committedDeparture, previous.state == snapshot.state,
           previous.alertStatus == snapshot.alertStatus,
           snapshot.state == .idle || snapshot.checkedAt <= previous.checkedAt || now < previous.expiresAt.addingTimeInterval(-60) {
            return false
        }
        return try PlanSnapshotStore.write(snapshot, to: defaults)
    }

    private static func sameDisplayedSamples(_ lhs: [DepartureEstimate], _ rhs: [DepartureEstimate], limits: WatchLimits) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.departure == $1.departure && $0.displayDrivingMinutes == $1.displayDrivingMinutes
                && $0.displayArrival == $1.displayArrival && limits.fits($0) == limits.fits($1)
        }
    }
}
