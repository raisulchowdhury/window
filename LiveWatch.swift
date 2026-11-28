import Foundation
#if !WINDOW_PORTABLE_TESTS
import Combine
import AppKit
import Network
#endif

@MainActor final class LiveWatch: ObservableObject {
    @Published var settings: SavedJourney { didSet { persistAcceptedSettings(previous: oldValue) } }
    @Published private(set) var usualSettings: SavedJourney
    @Published private(set) var settingsRevision = 0
    @Published private(set) var dayKey: String
    @Published private(set) var proposal: DepartureOffer?
    private var settingsDay: Date
    private var hydrating = false
    private var hasAcceptedDeparture = false
    @Published var screen = "setup"
    @Published private(set) var now: Date
    @Published private(set) var active = false
    @Published private(set) var checking = false
    @Published private(set) var checkingSamples: [DepartureEstimate] = []
    @Published private(set) var checkingExpectedCount = 0
    @Published private(set) var pendingDeparture: Date?
    @Published private(set) var plan: DepartureEstimate?
    @Published private(set) var batch: TrafficBatch?
    @Published private(set) var limits: WatchLimits?
    @Published private(set) var route: SavedJourney?
    @Published private(set) var pauseReason: String?
    @Published private(set) var message = ""
    @Published private(set) var recoveryOriginalLimits: WatchLimits?
    private var recoveryWrapUpDeparture: Date?
    private var recoveryPreparedDeparture: Date?
    @Published private(set) var initialBenefit: String?
    @Published private(set) var initialDeparture: Date?
    @Published private(set) var alertAuthorization: AlertAuthorization = .unknown
    /// Where this copy of the app runs from; tests set it. See AlertLaunchLocation.
    var bundlePath = Bundle.main.bundlePath
    @Published private(set) var alertError: String?
    @Published private(set) var cueSubmitted = false
    @Published private(set) var requestingAlertPermission = false
    @Published private(set) var testingAlert = false
    @Published private(set) var testAlertMessage = ""
    private var testAlertRevision = 0
    private var testAlertIDs = Set<String>()
    private var shuttingDown = false
    @Published private(set) var endTitle = ""
    @Published private(set) var endMessage = ""
    @Published private(set) var online = true
    @Published private(set) var sleeping = false
    let store: JourneyStore
    let provider: TrafficProviding
    let alerts: WatchAlerting
    private let clock: () -> Date
    private var gate = WatchRequestGate()
    private var requestTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var permissionIsExplicit = false
    private var pendingPermissionRequest = false
    private var timer: Timer?
    #if !WINDOW_PORTABLE_TESTS
    private var network: NWPathMonitor?
    private var observers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?
    #endif
    private var nextRefresh = Date.distantPast
    private var nextAlertAttempt = Date.distantPast
    private var notifiedDeparture: Date?
    /// The wrap-up nudge and the leave nudge each fire once per accepted departure,
    /// however often the watch pauses and resumes in between.
    private var notifiedPhases = Set<DepartureCuePhase>()
    private var notifiedRisk = false
    /// Stop is immediate; for a few seconds Undo restarts the watch and keeps
    /// the stopped departure if a fresh check still offers it.
    static let undoStopSeconds: TimeInterval = 8
    /// Retry delay after a failed check while a departure cue is due before the next regular check.
    static let cueRetrySeconds: TimeInterval = 30
    private var stoppedAt: Date?
    private var stoppedDeparture: Date?
    private var restoringDeparture: Date?
    private var failedCheckNeedsReview = false
    /// Apple Maps throttled the latest check; the next retry waits a full minute.
    private var lastCheckThrottled = false
    private var alertRevision = 0
    private var startedOn: Date?
    private var lastAuthorizationCheck = Date.distantPast
    private var alertIDs = Set<String>()
    /// Delivered alerts stay in Notification Center until the person ends the watch or a
    /// new departure replaces them. Cancelling only withdraws submissions still in flight.
    private var deliveredAlertIDs = Set<String>()

    init(store: JourneyStore, provider: TrafficProviding, alerts: WatchAlerting, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.provider = provider; self.alerts = alerts; self.clock = clock
        let date = clock()
        now = date; settingsDay = date; dayKey = JourneyDay.key(date)
        usualSettings = store.load(); settings = store.loadToday(on: date)
        screen = settings.routeID == nil ? "setup" : "home"
    }
    private func persistAcceptedSettings(previous: SavedJourney) {
        guard !hydrating else { return }
        if previous.appearance != settings.appearance {
            var usual = store.load(); usual.appearance = settings.appearance
            store.save(usual); usualSettings = usual
        }
        if !previous.sameJourney(as: settings) { settingsRevision += 1 }
        store.saveToday(settings, on: settingsDay)
    }
    /// Actions call this as well as the timer. Midnight must not leave a one-second
    /// opportunity to accept yesterday's offer or promote yesterday's settings.
    @discardableResult func synchronizeDay() -> Bool {
        now = clock()
        let key = JourneyDay.key(now)
        guard key != dayKey else { return false }
        if active { end(title: "Watch ended", message: "A new day has started.", keepDelivered: true) }
        hydrating = true
        settingsDay = now; dayKey = key
        usualSettings = store.load(); settings = store.loadToday(on: now)
        hydrating = false; settingsRevision += 1
        message = "A new day has started. Review today’s times."
        screen = settings.routeID == nil ? "setup" : "home"
        return true
    }
    func makeDraft() -> JourneyEdit {
        synchronizeDay()
        return JourneyEdit(day: dayKey, revision: settingsRevision, value: settings)
    }
    func draftError(_ edit: JourneyEdit, saveForFutureDays: Bool = false) -> String? {
        guard edit.day == dayKey else { return "The day changed. Open today’s journey again." }
        guard edit.revision == settingsRevision else { return "The journey changed in another window. Reopen it before editing." }
        guard let origin = edit.value.origin, let destination = edit.value.destination,
              edit.value.routeID != nil else { return "Choose and confirm both places." }
        guard origin.id != destination.id else { return "Choose two different places." }
        if saveForFutureDays {
            guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now),
                  let usual = edit.value.limits(on: tomorrow) else { return "Enter valid times for future days." }
            if let error = usual.validation(at: usual.earliest.addingTimeInterval(-usual.packing)) { return error }
        }
        var value = edit.value
        value.earliest = max(value.earliest, liveMinutes(now))
        guard let proposed = value.limits(on: now) else { return "Enter valid journey times." }
        // An unchanged edit must preserve an explicitly accepted recovery.
        if edit.value.sameJourney(as: settings), unchangedRecoveryJourney { return nil }
        if active, edit.value.routeID == route?.routeID, let plan,
           proposed.packing == limits?.packing, proposed.fits(plan), plan.departure >= now,
           proposed.earliest <= proposed.latest, proposed.latest < proposed.homeBy,
           proposed.latest.timeIntervalSince(proposed.earliest) <= 10800 { return nil }
        // With no watch, a passed window never locks the journey: it saves, and the panel
        // reports the passed window. Times that are invalid in themselves still block.
        // An active watch expires a minute after its latest leave, so it keeps the check.
        if !active, now.addingTimeInterval(proposed.packing) > proposed.latest {
            guard let requested = edit.value.limits(on: now) else { return "Enter valid journey times." }
            return requested.validation(at: requested.earliest.addingTimeInterval(-requested.packing))
        }
        return proposed.validation(at: now)
    }
    /// With no watch, a passed window saves (see draftError) but the panel still asks for new
    /// times. The journey editor shows this beside Save as a note, so Save never looks like it
    /// did nothing. It never blocks.
    func draftNote(_ edit: JourneyEdit, saveForFutureDays: Bool = false) -> String? {
        guard !active, draftError(edit, saveForFutureDays: saveForFutureDays) == nil,
              let requested = edit.value.limits(on: now),
              now.addingTimeInterval(requested.packing) > requested.latest else { return nil }
        return requested.validation(at: now)
    }
    @discardableResult func applyDraft(_ edit: JourneyEdit, saveForFutureDays: Bool = false) -> String? {
        synchronizeDay()
        if let error = draftError(edit, saveForFutureDays: saveForFutureDays) { return error }
        var accepted = edit.value; accepted.appearance = settings.appearance
        let wasActive = active
        settings = accepted
        if saveForFutureDays {
            store.save(accepted)
            usualSettings = accepted
        }
        if wasActive { begin() } else { screen = "home" }
        return nil
    }
    @discardableResult func makeUsualTimes() -> Bool {
        guard !synchronizeDay(), settings.valid else { return false }
        var usual = usualSettings
        usual.earliest = settings.earliest; usual.latest = settings.latest
        usual.homeBy = settings.homeBy; usual.packing = settings.packing
        usual.appearance = settings.appearance
        store.save(usual); usualSettings = usual
        message = "Usual times saved."
        return true
    }
    /// Saving a usual route is a separate explicit action, including the first route.
    func makeUsualRoute() {
        guard !synchronizeDay(), settings.routeID != nil else { return }
        var usual = usualSettings
        usual.origin = settings.origin; usual.destination = settings.destination
        store.save(usual); usualSettings = usual
        message = "Usual route saved."
    }
    var hasTodayTimes: Bool {
        settings.earliest != usualSettings.earliest || settings.latest != usualSettings.latest
            || settings.homeBy != usualSettings.homeBy || settings.packing != usualSettings.packing
    }
    var nextCheck: Date? { active && plan != nil && !stale && !needsNewDeparture && !checking && online && !sleeping ? max(now, nextRefresh) : nil }
    func offer(for choice: DepartureEstimate, baseline: DepartureEstimate? = nil, recovery: Bool = false) -> DepartureOffer? {
        guard let batch, let limits, active, !stale, !checking else { return nil }
        return DepartureOffer(choice: choice, baseline: baseline, batch: batch, limits: limits, recovery: recovery, requestedLimits: recoveryOriginalLimits ?? limits, session: gate.session)
    }
    /// An existing wrap-up finishes at its committed departure, not when its cue starts.
    private var preparationCompletion: Date? {
        recoveryPreparedDeparture ?? (wrapUp ? plan?.departure : nil)
    }
    func canAccept(_ offer: DepartureOffer) -> Bool {
        guard active, offer.session == gate.session, !stale, !checking, offer.matches(batch: batch, limits: limits, at: now) else { return false }
        if offer.recovery {
            return recoveryOptions.map { offer.choice == $0.primary || offer.choice == $0.alternative } == true
        }
        let ready = DeparturePolicy.readiness(now: now, limits: offer.limits,
            preparedFor: preparationCompletion)
        return offer.limits.fits(offer.choice) && offer.choice.departure >= ready
    }
    @discardableResult func acceptOffer(_ offer: DepartureOffer) -> Bool {
        guard !synchronizeDay(), canAccept(offer) else {
            message = "This choice needs a fresh check. Your saved limits are unchanged."
            return false
        }
        if offer.recovery { acceptRecovery(offer.choice); return true }
        cancelWork(); removeDeliveredAlerts(); gate.begin()
        proposal = nil; plan = offer.choice; hasAcceptedDeparture = true
        initialDeparture = offer.choice.departure
        initialBenefit = offer.baseline.map { "When chosen: " + tradeoffText(offer.choice, comparedWith: $0) }
        resetCueRecord()
        message = "Departure set to \(liveTime(offer.choice.departure))."
        screen = "watch"; updateAuthorization(request: true)
        return true
    }
    private var unchangedRecoveryJourney: Bool {
        guard active, recoveryOriginalLimits != nil, var saved = route else { return false }
        saved.appearance = settings.appearance
        return saved == settings
    }
    var validation: String? {
        if unchangedRecoveryJourney { return nil }
        guard let origin = settings.origin, let destination = settings.destination, settings.routeID != nil else { return "Choose and confirm both places." }
        if origin.id == destination.id { return "Choose two different places." }
        guard let limits = effectiveSettings.limits(on: now) else { return "Enter valid journey times." }
        if active, settings.routeID == route?.routeID {
            if limits == self.limits { return nil }
            if let plan, limits.packing == self.limits?.packing, limits.fits(plan), plan.departure >= now, limits.earliest <= limits.latest, limits.latest < limits.homeBy, limits.latest.timeIntervalSince(limits.earliest) <= 10800 { return nil }
        }
        // Once the window has passed, name that rather than the clamped earliest time.
        if now.addingTimeInterval(limits.packing) > limits.latest { return (settings.limits(on: now) ?? limits).validation(at: now) }
        return limits.validation(at: now)
    }
    var stale: Bool { active && (pauseReason != nil || !online || sleeping || batch.map { !$0.isFresh(at: now) } == true) }
    var needsNewDeparture: Bool { active && plan.map { now > $0.departure } == true }
    var cuePhase: DepartureCuePhase? {
        guard active, let plan, let limits else { return nil }
        return DepartureCuePhase.resolve(now: now, departure: plan.departure, packing: limits.packing,
                                         preparationAlreadyUnderway: recoveryWrapUpDeparture == plan.departure)
    }
    var missed: Bool { cuePhase == .missed }
    var risk: Bool { active && !checking && batch != nil && plan == nil && proposal == nil && !stale }
    var wrapUp: Bool { cuePhase.map { $0 != .waiting } ?? false }
    /// One cue for the screen, VoiceOver, and menu bar, including journeys with no packing time.
    var departureCue: String {
        guard let plan, let cuePhase else { return "" }
        let packing = limits?.packing ?? 0
        switch cuePhase {
        case .waiting:
            return packing == 0 ? "No wrap-up needed" : "Wrap up at \(liveTime(plan.departure.addingTimeInterval(-packing)))"
        case .wrappingUp: return "Wrap up now"
        case .leaveNow: return "Leave now"
        case .missed: return "Departure time passed"
        }
    }
    var status: String {
        if !active { return "Ready for today" }
        if sleeping { return "Paused · Mac asleep" }
        if !online { return "Paused · no connection" }
        if stale { return "Paused · plan unconfirmed" }
        if missed { return "Departure time passed" }
        if checking, let pendingDeparture { return "Checking \(liveTime(pendingDeparture))…" }
        if checking && batch == nil { return "Checking Apple Maps…" }
        if proposal != nil { return "Choose your departure" }
        if risk { return "Review a new departure" }
        if alertError != nil { return "Watching · alert needs attention" }
        if alertAuthorization != .allowed { return "Watching · " + alertStatusLabel.lowercased() }
        return "Watching"
    }
    var menuTitle: String {
        guard active else { return "" }
        if stale { return " Paused" }
        if missed || risk || proposal != nil { return " Check plan" }
        if checking && plan == nil { return " Checking" }
        if wrapUp { return cuePhase == .leaveNow ? " Leave now" : " Wrap up" }
        return plan.map { " Leave \(liveTime($0.departure))" } ?? ""
    }
    var canDelay: Bool { guard let plan, let limits else { return false }; return !stale && !missed && !checking && plan.departure.addingTimeInterval(300) <= limits.latest }
    var sooner: DepartureEstimate? {
        guard let batch, batch.isFresh(at: now), let limits, let plan else { return nil }
        let ready = DeparturePolicy.readiness(now: now, limits: limits, preparedFor: preparationCompletion)
        return batch.samples.filter { $0.departure >= ready && $0.departure < plan.departure && limits.fits($0) }.min { $0.departure < $1.departure }
    }
    var arrivalNote: String? {
        guard let plan, let original = recoveryOriginalLimits ?? limits else { return nil }
        let late = Int(ceil(plan.arrival.timeIntervalSince(original.homeBy) / 60))
        return late > 0 ? "About \(late) min later than you wanted." : nil
    }
    var planNotice: String? { message.isEmpty ? nil : message }
    func tradeoffText(_ choice: DepartureEstimate, comparedWith baseline: DepartureEstimate) -> String {
        DepartureTradeoff(choice, comparedWith: baseline).text
    }
    private var comparableChoices: [DepartureEstimate] {
        guard active, !stale, !checking, let limits, let batch, batch.isFresh(at: now), batch.routeID == route?.routeID else { return [] }
        let ready = DeparturePolicy.readiness(now: now, limits: limits, preparedFor: preparationCompletion)
        return batch.samples.filter { $0.valid && $0.departure >= ready && $0.departure <= limits.latest }
    }
    var planComparison: String? {
        guard !wrapUp, let plan, let chosen = batch?.sample(at: plan.departure),
              let first = comparableChoices.min(by: { $0.departure < $1.departure }) else { return nil }
        if first.departure < chosen.departure {
            return "Compared with leaving as soon as ready:\n" + tradeoffText(chosen, comparedWith: first)
        }
        if comparableChoices.count > 1, comparableChoices.allSatisfy({ chosen.driving - $0.driving < 8 * 60 }) {
            return "No meaningful reduction in driving among the checked times."
        }
        return nil
    }
    var drivingAlternative: DepartureEstimate? {
        guard let plan, batch?.sample(at: plan.departure) != nil else { return nil }
        let later = comparableChoices.filter { $0.departure > plan.departure && limits?.fits($0) == true }
        let choice = DeparturePolicy.meaningfulDriving([plan] + later)
        return choice?.departure == plan.departure ? nil : choice
    }
    var recoveryReadyToday: Bool {
        guard let limits else { return false }
        let ready = DeparturePolicy.readiness(now: now, limits: limits, preparedFor: recoveryPreparedDeparture)
        return Calendar.current.isDate(ready, inSameDayAs: now)
    }
    var recoveryOptions: RecoveryOptions? {
        guard active, plan == nil, proposal == nil, !stale, !checking, let limits, let batch,
              batch.isFresh(at: now), batch.routeID == route?.routeID else { return nil }
        return RecoveryPolicy.options(batch.samples, limits: limits, now: now, preparedFor: recoveryPreparedDeparture)
    }
    func recoveryImpact(_ choice: DepartureEstimate) -> String {
        guard let original = recoveryOriginalLimits ?? limits else { return "" }
        let late = Int(ceil(choice.arrival.timeIntervalSince(original.homeBy) / 60))
        return late > 0 ? "About \(late) min later than you wanted."
            : "Still within your requested arrival time."
    }
    /// The recovery window's one sentence, in the panel's words: when the drive arrives
    /// against the arrive-by, and what accepting changes. Every time comes from the policy.
    func recoveryConsent(_ choice: DepartureEstimate) -> String {
        guard let original = recoveryOriginalLimits ?? limits else { return "" }
        let accepted = RecoveryPolicy.acceptedLimits(for: choice, original: original)
        let spare = Int(accepted.buffer / 60), usual = Int(original.buffer / 60)
        var text: String
        if choice.arrival > original.homeBy {
            let late = Int(ceil(choice.arrival.timeIntervalSince(original.homeBy) / 60))
            // The latest arrival the accepted limits still fit, as fits() reads them.
            let arriveBy = accepted.homeBy.addingTimeInterval(-accepted.buffer)
            text = "Arrives about \(late) min after \(liveTime(original.homeBy)). Accept to watch with \(liveTime(arriveBy)) as today’s arrive-by."
        } else if accepted.buffer < original.buffer {
            text = spare == 0 ? "Arrives around \(liveTime(choice.displayArrival)), with no spare for traffic."
                : "Arrives around \(liveTime(choice.displayArrival)), with \(spare) min spare instead of \(usual)."
        } else {
            text = "Arrives around \(liveTime(choice.displayArrival)), with the usual \(usual) min spare."
        }
        if choice.departure > original.latest {
            text += " Leaves after your \(liveTime(original.latest)) latest leave."
        }
        return text
    }
    func recoveryAction(_ choice: DepartureEstimate) -> String {
        guard let limits else { return "Use this departure" }
        if limits.packing > 0 && choice.departure.timeIntervalSince(now) <= limits.packing + 60 { return "Start wrapping up" }
        return "Use this departure"
    }
    func acceptRecovery(_ choice: DepartureEstimate) {
        guard !synchronizeDay() else { return }
        guard let options = recoveryOptions, choice == options.primary || choice == options.alternative,
              let original = recoveryOriginalLimits ?? limits else { return }
        let accepted = RecoveryPolicy.acceptedLimits(for: choice, original: original)
        guard accepted.fits(choice) else { return }
        let startWrapping = accepted.packing > 0 && choice.departure.timeIntervalSince(now) <= accepted.packing + 60
        cancelWork(); removeDeliveredAlerts(); gate.begin()
        recoveryOriginalLimits = original
        limits = accepted; plan = choice; hasAcceptedDeparture = true; recoveryPreparedDeparture = nil; initialDeparture = choice.departure; initialBenefit = nil
        recoveryWrapUpDeparture = startWrapping ? choice.departure : nil
        resetCueRecord()
        message = ""
        screen = "watch"; updateAuthorization(request: true); maybeNotify()
    }
    var details: String {
        "Apple Maps estimates. Checks every three minutes while awake and online; estimates expire after five minutes. Spare: \(Int((limits?.buffer ?? 600) / 60)) min. This is not an on-time guarantee."
    }
    #if !WINDOW_PORTABLE_TESTS
    func activateRuntime() {
        guard timer == nil else { return }
        alerts.remove(ids: Array(alertIDs)); alertIDs.removeAll()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        let monitor = NWPathMonitor(); self.network = monitor
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.connectivityChanged(path.status == .satisfied) } }
        monitor.start(queue: DispatchQueue(label: "window.connection"))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSleeping(true) } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.setSleeping(false) } })
        updateAuthorization(request: false)
    }
    #endif
    var readyMinute: Int { max(settings.earliest, liveMinutes(now)) }
    var effectiveSettings: SavedJourney {
        var value = settings
        value.earliest = readyMinute
        return value
    }
    func begin() {
        synchronizeDay()
        stoppedAt = nil; stoppedDeparture = nil; restoringDeparture = nil
        if unchangedRecoveryJourney { screen = "watch"; return }
        guard validation == nil, let newLimits = effectiveSettings.limits(on: now) else { return }
        if active, settings.routeID == route?.routeID, let limits {
            let onlyClockAdvanced = newLimits.earliest == max(limits.earliest, Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now)
                && newLimits.latest == limits.latest && newLimits.homeBy == limits.homeBy && newLimits.packing == limits.packing
                && plan.map { newLimits.fits($0) && $0.departure >= now } == true
            if newLimits == limits || onlyClockAdvanced { screen = "watch"; return }
        }
        if active, settings.routeID == route?.routeID {
            let previous = plan
            let retain = previous.map { newLimits.fits($0) && $0.departure >= now && newLimits.packing == limits?.packing } ?? false
            cancelWork(); if !retain { removeDeliveredAlerts() }; gate.begin()
            recoveryOriginalLimits = nil; recoveryWrapUpDeparture = nil; recoveryPreparedDeparture = nil
            route = settings; limits = newLimits
            plan = retain ? previous : nil
            if retain { pauseReason = "Refreshing traffic after today’s limits changed." }
            else { batch = nil; pauseReason = nil }
            initialBenefit = nil
            if !retain { initialDeparture = nil; resetCueRecord() }
            screen = "watch"; refresh(); return
        }
        // A fresh watch (a new route, or a new watch after expiry) starts with none of the old alerts.
        cancelWork(); removeDeliveredAlerts(); gate.begin()
        recoveryOriginalLimits = nil; recoveryWrapUpDeparture = nil; recoveryPreparedDeparture = nil
        route = settings; limits = newLimits; startedOn = now
        active = true; hasAcceptedDeparture = false; plan = nil; batch = nil; pauseReason = nil; message = ""; initialBenefit = nil; initialDeparture = nil
        resetCueRecord()
        screen = "watch"
        #if !WINDOW_PORTABLE_TESTS
        if activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Watch the selected departure while this Mac is awake") }
        #endif
        updateAuthorization(request: false)
        refresh()
    }
    func updateAuthorization(request: Bool) {
        guard !shuttingDown else { return }
        guard permissionTask == nil else { if request && !permissionIsExplicit { pendingPermissionRequest = true }; return }
        permissionIsExplicit = request; requestingAlertPermission = true
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let authorization = await self.alerts.authorization(request: request)
            guard !Task.isCancelled else { return }
            self.alertAuthorization = authorization
            self.lastAuthorizationCheck = self.clock(); self.permissionTask = nil
            if self.alertAuthorization != .allowed { self.cancelAlerts() }
            if self.pendingPermissionRequest {
                self.pendingPermissionRequest = false
                self.updateAuthorization(request: true)
            } else {
                self.requestingAlertPermission = false
                if authorization == .allowed { self.maybeNotify(failedCheck: self.failedCheckNeedsReview) }
            }
        }
    }
    func tick() {
        // Idle, the panel shows minutes: publish the clock only when the minute or day
        // changes. Midnight changes the minute, so the day guarantee above still holds.
        let date = clock()
        let undoOpen = stoppedAt.map { date.timeIntervalSince($0) < Self.undoStopSeconds + 2 } ?? false
        if !active && !checking && !undoOpen && floor(date.timeIntervalSinceReferenceDate / 60) == floor(now.timeIntervalSinceReferenceDate / 60)
            && JourneyDay.key(date) == dayKey { return }
        if synchronizeDay() { return }
        guard active else { return }
        if let startedOn, !Calendar.current.isDate(startedOn, inSameDayAs: now) { end(title: "Watch expired", message: "The day changed. Start a new watch with today’s times.", keepDelivered: true); return }
        if let limits, now > limits.latest.addingTimeInterval(60) { end(title: "Watch expired", message: "Your latest departure passed. No alerts remain.", keepDelivered: true); return }
        if sleeping || !online { return }
        if missed { cancelAlerts(); return } // do not silently invent a new packing interval
        if pauseReason == nil && batch.map({ !$0.isFresh(at: now) }) == true { cancelAlerts() }
        // Keep a presented choice frozen. Expiry is visible and requires a recheck.
        // Permission refresh and failed alert retries still belong to this watch.
        if proposal == nil && now >= nextRefresh && !checking { refresh() }
        if now.timeIntervalSince(lastAuthorizationCheck) >= 60 { updateAuthorization(request: false) }
        maybeNotify(failedCheck: failedCheckNeedsReview)
    }
    func refresh(requested: Date? = nil, replan: Bool = false) {
        guard !synchronizeDay() else { return }
        guard active, let origin = route?.origin, let destination = route?.destination, let routeID = route?.routeID, let limits, let session = gate.session else { return }
        guard online && !sleeping else { pause("Traffic checks need this Mac to be awake and online. Choose Check again if your departure time passes."); return }
        // A delay is still available during the existing due-minute grace period.
        // Automatic checks must not silently replan a departure that has passed, but inside
        // the leave minute they still confirm it, so a Mac that wakes or reconnects at 17:30:20
        // still gets Time to leave instead of "Your departure time has passed".
        let leaveMinute = cuePhase == .leaveNow
        if let plan, now > plan.departure, !replan, missed || (requested == nil && !leaveMinute) { return }
        proposal = nil
        // Replanning drops the departure, so its delivered cues go too; the departure-change
        // check after the refresh cannot see this one because `plan` is already nil.
        if replan { plan = nil; recoveryPreparedDeparture = nil; initialBenefit = nil; removeDeliveredAlerts() }
        if let requested, requested < DeparturePolicy.readiness(now: now, limits: limits, preparedFor: preparationCompletion) || requested > limits.latest {
            message = "That departure no longer fits your limits."; return
        }
        requestTask?.cancel()
        let revision = gate.next()
        let commitment = plan?.departure
        let checkedAt = now
        var departures = DeparturePolicy.candidates(now: now, limits: limits, committed: commitment, requested: requested, preparedFor: preparationCompletion)
        // Candidates skip times already past; in the leave minute the watched departure is the one to confirm.
        if leaveMinute, let commitment, commitment < now, !departures.contains(commitment) { departures.append(commitment); departures.sort() }
        if departures.isEmpty {
            let ready = DeparturePolicy.readiness(now: now, limits: limits, preparedFor: recoveryPreparedDeparture)
            if Calendar.current.isDate(ready, inSameDayAs: now) { departures = [ready] }
        }
        guard !departures.isEmpty else {
            checking = false; pendingDeparture = nil; plan = nil; batch = TrafficBatch(routeID: routeID, checkedAt: now, samples: [])
            pauseReason = nil; message = "Your wrap-up time reaches tomorrow. This watch only covers today."
            cancelAlerts(); return
        }
        checkingSamples = []; checkingExpectedCount = departures.count
        checking = true; pendingDeparture = requested; message = ""
        nextRefresh = now.addingTimeInterval(180); lastCheckThrottled = false
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                var samples: [DepartureEstimate] = []
                var firstFailure: String?
                // Two requests at a time. DeparturePolicy.candidates returns at most 11 departures:
                // up to 9 on the grid including the latest leave, plus either the next-minute
                // option (new watch only, so 10) or the commitment and a requested time (11).
                for offset in stride(from: 0, to: departures.count, by: 2) {
                    try Task.checkCancellation()
                    let chunk = Array(departures[offset..<min(offset + 2, departures.count)])
                    let fetched = try await withThrowingTaskGroup(of: (DepartureEstimate?, String?, Bool).self) { group in
                        for date in chunk {
                            group.addTask {
                                do { return (try await self.provider.estimate(from: origin, to: destination, departing: date), nil, false) }
                                catch { try Task.checkCancellation(); return (nil, error.localizedDescription, error is MapsThrottledError) }
                            }
                        }
                        var values: [DepartureEstimate] = [], failure: String?, throttled = false
                        for try await (value, error, limited) in group {
                            if let value { values.append(value) } else { failure = failure ?? error }
                            throttled = throttled || limited
                        }
                        return (values, failure, throttled)
                    }
                    samples += fetched.0; firstFailure = firstFailure ?? fetched.1
                    guard self.gate.accepts(revision, session: session), self.active else { return }
                    self.checkingSamples = samples.sorted { $0.departure < $1.departure }
                    // Apple Maps is throttling: more requests now only extend the limit. Judge what arrived.
                    if fetched.2 { self.lastCheckThrottled = true; break }
                }
                guard self.gate.accepts(revision, session: session), self.active else { return }
                guard !self.synchronizeDay() else { return }
                if let commitment, requested == nil, self.now >= commitment.addingTimeInterval(60) {
                    self.checking = false; self.pendingDeparture = nil; self.requestTask = nil
                    self.cancelAlerts()
                    return
                }
                let newBatch = TrafficBatch(routeID: routeID, checkedAt: checkedAt, samples: samples.sorted { $0.departure < $1.departure })
                guard newBatch.isFresh(at: self.now) else {
                    self.checking = false; self.pendingDeparture = nil; self.requestTask = nil
                    self.pauseAfterFailedCheck("The check took too long. Your departure is unconfirmed.")
                    return
                }
                let preparedFor = self.preparationCompletion
                let ready = DeparturePolicy.readiness(now: self.now, limits: limits, preparedFor: preparedFor)
                let firstEligible = departures.first { $0 >= ready }
                let partial = samples.count < departures.count
                let essential = commitment.flatMap { departures.contains($0) ? $0 : nil } ?? requested ?? firstEligible
                let hasFeasibleSample = samples.contains { sample in
                    limits.fits(sample) && (sample.departure >= ready || sample.departure == commitment)
                }
                if samples.isEmpty || essential.map({ newBatch.sample(at: $0) == nil }) == true
                    || (partial && !hasFeasibleSample) {
                    // Keep the first Apple Maps cause; "refresh" keeps the panel's CHECK FAILED label.
                    switch firstFailure {
                    case MapsErrorCopy.noRoute?: self.pauseAfterFailedCheck("Couldn’t refresh traffic: Apple Maps found no route for this journey.")
                    case MapsErrorCopy.notResponding?: self.pauseAfterFailedCheck("Couldn’t refresh traffic: Apple Maps isn’t responding. Try again.")
                    default: self.pauseAfterFailedCheck("Couldn’t refresh enough traffic estimates. Try again.")
                    }
                    return
                }
                if self.pauseReason != nil {
                    // Fresh evidence makes the "couldn't confirm traffic" warning untrue: withdraw it.
                    self.cancelAlerts(); self.notifiedRisk = false
                    let warnings = self.deliveredAlertIDs.filter { $0.hasSuffix(".unconfirmed") }
                    if !warnings.isEmpty { self.alerts.remove(ids: Array(warnings)); self.deliveredAlertIDs.subtract(warnings) }
                }
                self.failedCheckNeedsReview = false
                self.batch = newBatch; self.pauseReason = nil; self.checking = false; self.pendingDeparture = nil
                let previous = self.plan
                if let requested {
                    if let choice = newBatch.sample(at: requested), requested >= ready, limits.fits(choice) { self.plan = choice; self.message = "Departure set to \(liveTime(choice.departure))."; self.initialBenefit = nil }
                    else {
                        self.plan = previous.flatMap { newBatch.sample(at: $0.departure) }.flatMap { limits.fits($0) ? $0 : nil }
                        if self.plan != nil && newBatch.sample(at: requested) == nil {
                            self.message = "Couldn’t check that departure. Your previous plan is unchanged."
                        } else {
                            self.message = self.plan == nil ? "Traffic no longer fits your limits." : "That departure does not fit. Your previous plan is unchanged."
                        }
                    }
                } else if let commitment, self.now > commitment {
                    // Keep the exact departure only while the refreshed estimate still fits.
                    self.plan = newBatch.sample(at: commitment).flatMap { limits.fits($0) ? $0 : nil }
                    if self.plan == nil { self.message = "Traffic no longer fits your limits." }
                } else {
                    let recommended = DeparturePolicy.recommend(samples, limits: limits, now: self.now, committed: commitment, preparedFor: preparedFor)
                    if let recommended, recommended.departure != commitment {
                        let baseline = samples.filter { $0.valid && $0.departure >= ready && limits.fits($0) }.min { $0.departure < $1.departure }
                        self.proposal = DepartureOffer(choice: recommended, baseline: baseline, batch: newBatch, limits: limits, session: session)
                        self.plan = nil
                    } else { self.plan = recommended }
                    if self.initialDeparture == nil, let chosen = self.plan {
                        self.initialDeparture = chosen.departure
                        if let first = samples.filter({ $0.departure >= departures[0] }).min(by: { $0.departure < $1.departure }), first.departure < chosen.departure {
                            self.initialBenefit = "At start: " + self.tradeoffText(chosen, comparedWith: first)
                        }
                    } else if previous?.departure != self.plan?.departure {
                        self.initialBenefit = nil
                        self.message = self.proposal != nil ? "Traffic changed. Review a new departure." : self.plan == nil ? "Traffic no longer fits your limits." : "Traffic changed. Your departure was updated."
                    }
                }
                if self.plan == nil, let previous,
                   previous.departure.addingTimeInterval(-limits.packing) <= self.now {
                    // Traffic changed during an existing wrap-up; do not add preparation again.
                    self.recoveryPreparedDeparture = previous.departure
                }
                if self.proposal != nil && partial { self.message = "Some departure times could not be checked." }
                // Any change of departure, including to none, withdraws the old departure's cues.
                // maybeNotify below then sends the risk alert when nothing is chosen.
                if previous?.departure != self.plan?.departure { self.removeDeliveredAlerts(); self.resetCueRecord() }
                self.requestTask = nil
                if let restore = self.restoringDeparture {
                    self.restoringDeparture = nil
                    if self.plan?.departure != restore, let sample = newBatch.sample(at: restore),
                       let offer = self.offer(for: sample), self.canAccept(offer) { _ = self.acceptOffer(offer) }
                }
                self.maybeNotify()
            } catch {
                guard self.gate.accepts(revision, session: session), self.active else { return }
                self.checking = false; self.pendingDeparture = nil; self.requestTask = nil
                self.message = ""
                self.pauseAfterFailedCheck("Couldn’t refresh traffic estimates. Try again.")
            }
        }
    }
    func choose(_ date: Date) { guard !synchronizeDay(), !stale && !missed && !checking else { return }; refresh(requested: date) }
    func delay() { guard !synchronizeDay(), canDelay, let plan else { return }; refresh(requested: plan.departure.addingTimeInterval(300)) }
    private func pauseAfterFailedCheck(_ reason: String) {
        restoringDeparture = nil
        let preserveNotice = alertIDs.contains { $0.hasSuffix(".unconfirmed") } && (notificationTask != nil || notifiedRisk)
        // A warning already in Notification Center still covers this failing streak, even after
        // a pause cleared `alertIDs`. A successful check removes it, so the next failure warns again.
        let warned = deliveredAlertIDs.contains { $0.hasSuffix(".unconfirmed") }
        if !preserveNotice && !warned { notifiedRisk = false }
        pause(reason, preserveReviewNotice: preserveNotice)
        // When a wrap-up or leave cue falls due before the next regular check, retry soon, so
        // one blip in the last minutes does not cost the leave alert.
        if let plan, let limits, plan.departure.addingTimeInterval(-limits.packing) <= nextRefresh,
           now < plan.departure.addingTimeInterval(60) {
            nextRefresh = min(nextRefresh, now.addingTimeInterval(lastCheckThrottled ? 60 : Self.cueRetrySeconds))
        }
        failedCheckNeedsReview = true
        maybeNotify(failedCheck: true)
    }
    func pause(_ reason: String, preserveReviewNotice: Bool = false) {
        guard active else { return }
        _ = gate.next(); requestTask?.cancel(); requestTask = nil; checking = false; pendingDeparture = nil; pauseReason = reason
        failedCheckNeedsReview = false
        if !preserveReviewNotice { cancelAlerts() }
    }
    func connectivityChanged(_ available: Bool) {
        guard available != online else { return }; online = available
        if !available { pause("Traffic checks are paused while this Mac is offline. Choose Check again if your departure time passes.") }
        else if active && !sleeping { refresh() }
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { pause("Traffic checks are paused while this Mac sleeps. Choose Check again if your departure time passes.") }
        else if active { tick(); if active && !missed { refresh() } }
    }
    func cancelAlerts() {
        alertRevision += 1; notificationTask?.cancel(); notificationTask = nil
        alerts.remove(ids: Array(alertIDs.subtracting(deliveredAlertIDs))); alertIDs.removeAll()
    }
    /// A new departure, or a new watch, may send its own wrap-up and leave alerts.
    private func resetCueRecord() { notifiedDeparture = nil; notifiedPhases = []; notifiedRisk = false; cueSubmitted = false }
    private func removeDeliveredAlerts() {
        cancelAlerts()
        guard !deliveredAlertIDs.isEmpty else { return }
        alerts.remove(ids: Array(deliveredAlertIDs)); deliveredAlertIDs.removeAll()
    }
    func maybeNotify(failedCheck: Bool = false) {
        guard !synchronizeDay() else { return }
        guard active, hasAcceptedDeparture, !missed, online, !sleeping, alertAuthorization == .allowed,
              permissionTask == nil, notificationTask == nil, now >= nextAlertAttempt else { return }
        let title: String, body: String, isRisk: Bool
        if failedCheck {
            guard stale, !notifiedRisk else { return }
            title = "Check your departure"
            body = "Window couldn’t confirm traffic. Open Window to recheck your plan."
            isRisk = true
        } else {
            guard batch?.isFresh(at: now) == true, !stale else { return }
            if (risk || proposal != nil) && !notifiedRisk {
                title = "Check your departure"
                body = "Traffic changed. Open Window to review a new departure."
                isRisk = true
            } else if wrapUp, let plan, let phase = cuePhase, phase != .missed,
                      notifiedDeparture != plan.departure || !notifiedPhases.contains(phase) {
                // Two nudges per departure: wrap up, then leave. A Mac that slept
                // through wrap-up still gets the leave nudge.
                title = phase == .leaveNow ? "Time to leave" : "Time to wrap up"
                body = phase == .leaveNow
                    ? "Arrive around \(liveTime(plan.displayArrival)) if you go now."
                    : "Leave at \(liveTime(plan.departure)). Arrive around \(liveTime(plan.displayArrival))."
                isRisk = false
            } else { return }
        }
        let revision = alertRevision, session = gate.session, departure = plan?.departure
        let phase = cuePhase
        let kind = failedCheck ? "unconfirmed" : isRisk ? "risk" : phase == .leaveNow ? "leave" : "wrapup"
        let identifier = "window.live.\(session?.uuidString ?? UUID().uuidString).\(revision).\(kind)"
        alertIDs.insert(identifier)
        notificationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.alertRevision == revision { self.notificationTask = nil } }
            guard !Task.isCancelled, self.alertRevision == revision,
                  self.permissionTask == nil, self.alertAuthorization == .allowed else {
                self.alertIDs.remove(identifier)
                return
            }
            do {
                try await self.alerts.deliver(id: identifier, title: title, body: body)
                // Delivery can suspend across a clock/day boundary without a timer tick.
                self.synchronizeDay()
                guard self.active, self.gate.session == session, self.alertRevision == revision,
                      self.online, !self.sleeping, !self.missed,
                      failedCheck ? self.stale : self.batch?.isFresh(at: self.now) == true && !self.stale else {
                    self.alerts.remove(ids: [identifier]); self.alertIDs.remove(identifier); return
                }
                if failedCheck {
                    // The review warning replaces cues that can no longer be trusted.
                    let replaced = self.deliveredAlertIDs; self.alerts.remove(ids: Array(replaced))
                    self.alertIDs.subtract(replaced); self.deliveredAlertIDs.removeAll()
                    // Window withdrew those cues, so the current one may be sent again once
                    // traffic is confirmed. That is a replacement, not a repeat.
                    if !replaced.isEmpty { self.notifiedPhases = [] }
                }
                self.deliveredAlertIDs.insert(identifier)
                if !isRisk, let phase {
                    if self.notifiedDeparture != departure { self.notifiedPhases = [] }
                    self.notifiedDeparture = departure; self.notifiedPhases.insert(phase); self.cueSubmitted = true
                }
                else { self.notifiedRisk = true }
                self.alertError = nil
            } catch { if self.active && self.alertRevision == revision { self.alertError = "macOS could not post the alert. Keep Window visible."; self.nextAlertAttempt = self.clock().addingTimeInterval(60) } }
        }
    }
    /// A test belongs to the controller, not to a particular details popover.
    /// Repeated clicks and another open surface cannot submit another test while
    /// one is pending. Closing a details view does not revoke an explicit test.
    func testAlert() async -> String {
        guard !shuttingDown else { return "Window has stopped." }
        guard !testingAlert else { return "A test alert is already being sent." }
        testingAlert = true; testAlertMessage = ""
        let revision = testAlertRevision
        defer { if revision == testAlertRevision { testingAlert = false } }
        // Join the same permission pipeline as Enable alerts and acceptance.
        // A passive read can queue an explicit request; await the entire chain.
        updateAuthorization(request: true)
        while let permissionTask {
            await permissionTask.value
            guard revision == testAlertRevision, !Task.isCancelled else { return "Test alert cancelled." }
        }
        guard revision == testAlertRevision, !Task.isCancelled else { return "Test alert cancelled." }
        guard alertAuthorization == .allowed else {
            testAlertMessage = "Alerts are not enabled in macOS."
            return testAlertMessage
        }
        let identifier = "window.live.test.\(UUID().uuidString)"
        testAlertIDs.insert(identifier)
        do {
            try await alerts.deliver(id: identifier, title: "Window test alert", body: "This checks macOS alerts. It does not start a watch.")
            guard revision == testAlertRevision, !Task.isCancelled else {
                alerts.remove(ids: [identifier]); testAlertIDs.remove(identifier)
                return "Test alert cancelled."
            }
            testAlertMessage = "Test alert submitted to macOS. Check that you received it."
        } catch {
            alerts.remove(ids: [identifier]); testAlertIDs.remove(identifier)
            guard revision == testAlertRevision else { return "Test alert cancelled." }
            testAlertMessage = "macOS rejected the test alert: \(error.localizedDescription)"
        }
        return testAlertMessage
    }
    var canRecheck: Bool { active && !checking && online && !sleeping }
    /// User-facing retries are single-flight. Internal refreshes still retain
    /// their cancellation/revision semantics for changed routes and limits.
    @discardableResult func recheck(replan: Bool = false) -> Bool {
        guard !synchronizeDay(), canRecheck else { return false }
        refresh(replan: replan)
        return checking
    }
    var delayUnavailableReason: String? {
        if checking { return "Wait for the current traffic check to finish." }
        if stale { return "Check traffic again before changing the departure." }
        if missed { return "Your departure passed. Choose Check again." }
        guard let plan, let limits else { return "Choose a departure first." }
        if plan.departure.addingTimeInterval(300) > limits.latest {
            return "Five more minutes would pass your \(liveTime(limits.latest)) departure limit."
        }
        return nil
    }
    private func cancelWork() { failedCheckNeedsReview = false; proposal = nil; _ = gate.next(); requestTask?.cancel(); requestTask = nil; checking = false; pendingDeparture = nil; cancelAlerts() }
    /// Ending by the person's action (stop, leaving, an edit) also clears delivered alerts.
    func finish(title: String, message: String) { end(title: title, message: message, keepDelivered: false) }
    private func end(title: String, message: String, keepDelivered: Bool) {
        stoppedAt = nil; stoppedDeparture = nil; restoringDeparture = nil
        cancelWork(); if !keepDelivered { removeDeliveredAlerts() }; resetCueRecord(); gate.stop(); active = false; hasAcceptedDeparture = false; plan = nil; batch = nil; pauseReason = nil
        endTitle = title; endMessage = message; screen = "finished"
        limits = nil; route = nil; recoveryOriginalLimits = nil
        recoveryWrapUpDeparture = nil; recoveryPreparedDeparture = nil
        initialBenefit = nil; initialDeparture = nil; startedOn = nil
        #if !WINDOW_PORTABLE_TESTS
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        #endif
    }
    var canUndoStop: Bool {
        guard !active, let stoppedAt else { return false }
        let elapsed = now.timeIntervalSince(stoppedAt)
        return elapsed >= 0 && elapsed < Self.undoStopSeconds
    }
    func stopWatching() {
        guard active else { return }
        let departure = plan?.departure
        finish(title: "Watch stopped", message: "Departure alerts have stopped.")
        stoppedAt = now; stoppedDeparture = departure
    }
    /// Restarts with today's journey. The stopped departure comes back only if the
    /// fresh check still offers it; otherwise the person reviews a new suggestion.
    @discardableResult func undoStop() -> Bool {
        guard !synchronizeDay(), canUndoStop else { return false }
        let departure = stoppedDeparture
        begin()
        guard active else { return false }
        restoringDeparture = departure
        return true
    }
    func shutdown() {
        shuttingDown = true; testAlertRevision += 1; testingAlert = false; requestingAlertPermission = false
        alerts.remove(ids: Array(testAlertIDs)); testAlertIDs.removeAll()
        // Quitting ends the watch: nothing it said stays behind once Window is gone.
        cancelWork(); removeDeliveredAlerts(); gate.stop(); active = false
        permissionTask?.cancel(); permissionTask = nil; pendingPermissionRequest = false
        timer?.invalidate(); timer = nil
        #if !WINDOW_PORTABLE_TESTS
        network?.cancel(); network = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        #endif
    }
}
/// One clock everywhere, matching the ruler: 24-hour, zero-padded.
func liveTime(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
func liveMinutes(_ date: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: date); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }

/// macOS refuses notification permission (UNErrorDomain code 1) to an app it cannot find by
/// bundle ID. A copy run from a temporary folder is one: App Translocation, which runs an app
/// opened from Downloads without being moved, uses /private/var/folders. Measured 2026-11-27 on
/// macOS 27.2: an ad-hoc signed, sandboxed probe got code 1 from /private/tmp and $TMPDIR, and the
/// real permission prompt from ~/Applications, ~/ and DerivedData.
enum AlertLaunchLocation {
    static func blocksAlerts(bundlePath: String) -> Bool {
        if bundlePath.contains("/AppTranslocation/") { return true }
        return ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"].contains { bundlePath.hasPrefix($0) }
    }
    /// A refused request leaves macOS "not determined", so a later passive read would say
    /// Not set up and offer Enable alerts, which cannot work from here. Keep it Unavailable.
    static func authorization(_ status: AlertAuthorization, bundlePath: String) -> AlertAuthorization {
        status == .unknown && blocksAlerts(bundlePath: bundlePath) ? .unavailable : status
    }
}

// Shared copy for the main window, Settings and details. Permission is distinct
// from a failed submission, and neither is evidence that an alert was seen.
extension LiveWatch {
    var alertStatusLabel: String {
        switch alertAuthorization {
        case .unknown: return "Alerts not set up"
        case .denied: return "Alerts off"
        case .unavailable: return "Alerts unavailable"
        case .allowed: return alertError == nil ? "Alerts allowed" : "Alert problem"
        }
    }
    /// The alert permission as a row value: one or two words.
    var alertShortStatus: String {
        switch alertAuthorization {
        case .unknown: return "Not set up"
        case .denied: return "Off"
        case .unavailable: return "Unavailable"
        case .allowed: return alertError == nil ? "Allowed" : "Not sent"
        }
    }
    var alertSummary: String {
        switch alertAuthorization {
        case .unknown: return "Notification permission has not been requested."
        case .denied: return "Notifications are off. Traffic estimates still work."
        case .unavailable:
            return AlertLaunchLocation.blocksAlerts(bundlePath: bundlePath)
                ? "Move Window to Applications, then open it again to use alerts. Traffic estimates still work."
                : "Notifications are unavailable for this build. Traffic estimates still work."
        case .allowed:
            return alertError == nil ? "Notifications are allowed in macOS."
                : "Notifications are allowed, but the last alert could not be sent."
        }
    }
    /// Why alerts cannot be tested when macOS reports them unavailable, in one line.
    var alertUnavailableReason: String {
        AlertLaunchLocation.blocksAlerts(bundlePath: bundlePath)
            ? "Move Window to Applications and open it again to use alerts."
            : "Alerts are unavailable on this Mac."
    }
    var departureAcceptanceNote: String {
        switch alertAuthorization {
        case .unknown: return "Choose a departure, then allow notifications when asked."
        case .denied: return "Choose a departure to watch on screen. Notifications are off."
        case .unavailable: return "Choose a departure to watch on screen. Alerts are unavailable."
        case .allowed: return alertError == nil ? "Choose a departure to start watching."
            : "Choose a departure to watch on screen. Review the alert problem in Details."
        }
    }
    var staleHeading: String {
        if sleeping { return "Watching is paused" }
        if !online { return "No internet connection" }
        return "Traffic needs a fresh check"
    }
    var staleExplanation: String {
        // Automatic refresh stops as soon as the committed departure is past,
        // before the one-minute missed threshold. Match the offered recheck action.
        if needsNewDeparture {
            if sleeping { return "Your departure time has passed. When this Mac wakes and reconnects, choose Check again." }
            if !online { return "Your departure time has passed. Reconnect, then choose Check again." }
            return "Your departure time has passed. Choose Check again to check another departure."
        }
        if sleeping { return "Checks resume when this Mac wakes and reconnects." }
        if !online { return "Checks resume when this Mac is back online." }
        return pauseReason ?? "The last traffic check has expired. Check again before relying on a departure."
    }
    var usualSettingsNotice: String? {
        ["Usual times saved.", "Usual route saved."].contains(message) ? message : nil
    }
}
