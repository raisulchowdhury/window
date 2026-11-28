import Foundation

public enum PanelChange: Equatable {
    case scrubStep, park, returnHome, batchSettled, batchRefreshed, phase
    case commit, delayLanded, paused, resumed, ended, clockTick, opened
    case checkingStarted, checkingProgress, feedback

    public static func classify(previous: RulerModel.PanelSnapshot?, next: RulerModel.PanelSnapshot) -> Self {
        guard let previous else { return .opened }
        if next.state == .noRoute && previous.state != .noRoute { return .ended }
        if next.state == .checking {
            return previous.state == .checking ? .checkingProgress : .checkingStarted
        }
        if next.state == .paused || next.state == .stale {
            if previous.state != next.state || previous.headerRight != next.headerRight { return .paused }
            return .clockTick
        }
        if previous.state == .checking { return .batchSettled }
        if previous.state == .paused || previous.state == .stale { return .resumed }
        if next.state == .watching && previous.state != .watching { return .commit }
        if next.committedDeparture != previous.committedDeparture && next.state == .watching { return .delayLanded }
        if next.state == .suggested && previous.state == .watching { return .batchRefreshed }
        if let feedback = next.feedbackLabel, feedback != previous.feedbackLabel { return .feedback }
        if next.state == .watching && next.phase != previous.phase { return .phase }
        if next.model?.batch.checkedAt != previous.model?.batch.checkedAt || next.model?.samples != previous.model?.samples {
            return .batchRefreshed
        }
        if next.headerRight != previous.headerRight && next.feedbackLabel != previous.feedbackLabel { return .feedback }
        return .clockTick
    }
}

extension RulerModel {
    /// Static presentation input; the controller supplies the actual commitment and freshness state.
    public struct PanelSnapshot {
        public let state: State
        public let limits: WatchLimits
        public let now: Date
        public let calendar: Calendar
        public let model: RulerModel?
        public let routeTitle: String
        public let committedDeparture: Date?
        public let expectedCount: Int
        public let receivedCount: Int
        public let isChecking: Bool
        public let checkingKeepsEvidence: Bool
        public let checkingSamples: [DepartureEstimate]
        public let newestBarProgress: Double
        public let readyForToday: Bool
        public let acceptableDepartures: Set<Date>?
        public let offerSession: UUID?
        public let primaryAvailable: Bool?
        public let delayAvailable: Bool?
        public let recheckAvailable: Bool
        public let preparationAlreadyUnderway: Bool
        public let pauseLabel: String?
        public let alertsOff: Bool
        public let alertStatus: String?
        /// A watch was just stopped; the capsule offers Undo for a few seconds.
        public let undoStopAvailable: Bool
        public let primaryIsRecheck: Bool
        public private(set) var feedbackLabel: String?
        public let endAnnouncement: String?
        public static let headerLeftBounds = 12.0...174.0
        public static let headerRightBounds = 186.0...348.0

        public init(state: State, limits: WatchLimits, now: Date, calendar: Calendar = .current,
                    model: RulerModel? = nil, routeTitle: String = "", committedDeparture: Date? = nil,
                    expectedCount: Int = 0, receivedCount: Int = 0, newestBarProgress: Double = 1,
                    isChecking: Bool = false, checkingKeepsEvidence: Bool = false,
                    checkingSamples: [DepartureEstimate] = [],
                    readyForToday: Bool = false, acceptableDepartures: Set<Date>? = nil, offerSession: UUID? = nil,
                    primaryAvailable: Bool? = nil, delayAvailable: Bool? = nil,
                    recheckAvailable: Bool = true, preparationAlreadyUnderway: Bool = false,
                    primaryIsRecheck: Bool = false, pauseLabel: String? = nil, feedbackLabel: String? = nil,
                    endAnnouncement: String? = nil, alertsOff: Bool = false, alertStatus: String? = nil,
                    undoStopAvailable: Bool = false) {
            self.undoStopAvailable = undoStopAvailable
            self.feedbackLabel = feedbackLabel
            self.endAnnouncement = endAnnouncement
            self.alertsOff = alertsOff
            self.alertStatus = alertStatus
            self.readyForToday = readyForToday; self.acceptableDepartures = acceptableDepartures
            self.offerSession = offerSession
            self.primaryAvailable = primaryAvailable; self.delayAvailable = delayAvailable
            self.recheckAvailable = recheckAvailable; self.preparationAlreadyUnderway = preparationAlreadyUnderway
            self.pauseLabel = pauseLabel; self.primaryIsRecheck = primaryIsRecheck
            self.state = state; self.limits = limits; self.now = now; self.calendar = calendar
            self.model = model; self.routeTitle = routeTitle; self.committedDeparture = committedDeparture
            self.expectedCount = max(0, expectedCount)
            self.receivedCount = max(0, min(receivedCount, max(checkingSamples.count, model?.samples.count ?? 0)))
            self.isChecking = isChecking || state == .checking
            self.checkingKeepsEvidence = checkingKeepsEvidence
            self.checkingSamples = checkingSamples
            self.newestBarProgress = min(1, max(0, newestBarProgress))
        }

        public func replacingFeedbackLabel(_ label: String?) -> Self {
            var copy = self
            copy.feedbackLabel = label
            return copy
        }

        private var selectedIndex: Int? {
            guard let model else { return nil }
            if let committedDeparture, state == .watching || state == .paused || state == .stale || checkingKeepsEvidence {
                return model.samples.firstIndex { $0.departure == committedDeparture } ?? model.suggestionIndex
            }
            return model.suggestionIndex
        }
        /// A watched commitment is the idle ruler's origin, including after choosing another sample.
        public var scrubModel: RulerModel? {
            guard let model, let selectedIndex else { return nil }
            guard selectedIndex != model.suggestionIndex else { return model }
            return RulerModel(batch: model.batch, limits: model.limits,
                suggestedDeparture: model.samples[selectedIndex].departure, calendar: calendar,
                comparisonBaseline: model.comparisonBaseline, originalArrivalLimits: model.originalArrivalLimits)
        }
        public func bars(reduceMotion: Bool) -> [SampleBar] {
            guard reduceMotion, state == .checking else { return bars }
            return PanelSnapshot(state: state, limits: limits, now: now, calendar: calendar, model: model,
                routeTitle: routeTitle, committedDeparture: committedDeparture, expectedCount: expectedCount,
                receivedCount: receivedCount, newestBarProgress: 1, isChecking: isChecking,
                checkingKeepsEvidence: checkingKeepsEvidence, checkingSamples: checkingSamples).bars
        }
        public var rows: [Row] {
            if state == .noRoute || state == .checking && !checkingKeepsEvidence {
                var rows = placeholderRows(state: state, limits: limits, calendar: calendar)
                if state == .noRoute && readyForToday {
                    rows[0].label = placeholderRows(state: .checking, limits: limits, calendar: calendar)[0].label
                } else if state == .noRoute {
                    rows[1] = Row(label: "WRAP-UP TIME", status: "", glyph: .none, name: "Wrap up", value: "—", valDim: true)
                    rows[3].label = "ARRIVE BY"
                } else {
                    rows[0].status = ""
                    rows[0].glyph = .none
                }
                return rows
            }
            guard let model, let selectedIndex else {
                var rows = placeholderRows(state: .noRoute, limits: limits, calendar: calendar)
                rows[0].label = "NO CHECKED DEPARTURE"
                rows[0].status = "UNCONFIRMED"; rows[0].glyph = .pause
                return rows
            }
            var rows = model.rows(at: selectedIndex, now: now, state: checkingKeepsEvidence ? .stale : state,
                                  committedDeparture: committedDeparture, preparationAlreadyUnderway: preparationAlreadyUnderway,
                                  alertsOff: alertsOff)
            if state == .watching && isChecking && feedbackLabel?.hasPrefix("CHECKING ") == true {
                rows[0].status = "CHECKING"; rows[0].glyph = .dots
            }
            return rows
        }
        fileprivate var phase: DepartureCuePhase? {
            guard state == .watching, let committedDeparture else { return nil }
            return DepartureCuePhase.resolve(now: now, departure: committedDeparture, packing: limits.packing, preparationAlreadyUnderway: preparationAlreadyUnderway)
        }
        public var headerLeft: String { state == .noRoute && !readyForToday ? "NO ROUTE YET" : routeTitle.uppercased() }
        public var headerRight: String {
            if state == .noRoute && undoStopAvailable { return "WATCH STOPPED" }
            if let feedbackLabel { return feedbackLabel }
            switch state {
            case .noRoute: return readyForToday ? "READY FOR TODAY" : "SETUP"
            case .checking: return "CHECKING \(receivedCount)/\(expectedCount)"
            case .suggested: return "SUGGESTED · NOT WATCHING"
            case .watching:
                return phase == .missed ? "CHECK PLAN" : alertsOff ? "WATCHING · ALERTS OFF" : "WATCHING"
            case .paused: return pauseLabel ?? "PAUSED"
            case .stale: return "CHECK EXPIRED"
            case .noFit: return "NO DEPARTURE FITS"
            }
        }
        /// The Drive row's minutes: the same sample the rows show. Nil before any check.
        private var driveMinutes: Int? {
            guard let model, let selectedIndex, model.samples.indices.contains(selectedIndex) else { return nil }
            return model.samples[selectedIndex].displayDrivingMinutes
        }
        public var headerLit: Bool { feedbackLabel != nil || state == .watching && phase != .missed }
        public var menuTitle: String {
            switch state {
            case .noRoute: return ""
            case .checking: return " Checking"
            case .suggested, .noFit: return " Check plan"
            case .paused, .stale: return " Paused"
            case .watching:
                switch phase {
                case .waiting:
                    // The leave time alone next to the icon. macOS hides a crowded menu bar's
                    // item whole when it is too wide, so the drive minutes stay in the panel's
                    // Drive row and the spoken label below.
                    guard let leave = rows.first?.value, !leave.isEmpty else { return "" }
                    return " \(leave)"
                case .wrappingUp: return " Wrap up"
                case .leaveNow: return " Leave now"
                case .missed: return " Check plan"
                case nil: return ""
                }
            }
        }
        /// What VoiceOver says for the menu bar title: "leave at 17:30, 31 minute drive", never
        /// "· 31m", which reads as metres. Empty when there is no title.
        public var menuSpokenTitle: String {
            guard state == .watching, phase == .waiting else { return menuTitle.trimmingCharacters(in: .whitespaces).lowercased() }
            let leave = "leave at \(rows.first?.value ?? "")"
            return driveMinutes.map { "\(leave), \($0) minute drive" } ?? leave
        }
        /// The primary action is "I'm leaving". Callers act on this, never on the display string.
        public var capsuleLeaves: Bool { !primaryIsRecheck && state == .watching && phase != .missed }
        public var capsule: String {
            if primaryIsRecheck { return "CHECK AGAIN" }
            switch state {
            case .noRoute:
                if undoStopAvailable { return "UNDO" }
                if readyForToday && feedbackLabel == "EDIT JOURNEY TIMES" { return "EDIT TIMES" }
                return readyForToday ? "CHECK TIMES" : "SET ROUTE"
            case .checking: return "CHECKING"
            case .suggested: return "WATCH \(rows.first?.value ?? "")"
            case .watching: return capsuleLeaves ? "I’M LEAVING" : "CHECK AGAIN"
            case .paused, .stale: return "CHECK AGAIN"
            case .noFit:
                guard model != nil else { return "CHECK AGAIN" }
                return "REVIEW \(rows.first?.value ?? "") · \(rows.last?.status ?? "")"
            }
        }
        public func canUseSample(_ sample: DepartureEstimate, previewedIn frozen: PanelSnapshot? = nil) -> Bool {
            guard state == .suggested || state == .noFit else { return false }
            guard !isChecking, model?.samples.contains(sample) == true else { return false }
            if let frozen {
                guard frozen.canUseSample(sample), frozen.limits == limits,
                      frozen.offerSession == offerSession,
                      frozen.model?.batch.routeID == model?.batch.routeID,
                      frozen.model?.batch.checkedAt == model?.batch.checkedAt else { return false }
            }
            return acceptableDepartures?.contains(sample.departure) ?? limits.fits(sample)
        }
        public var earlierDeparture: Date? {
            guard state == .suggested, let model else { return nil }
            return model.samples.filter { $0.departure < model.suggestion.departure && canUseSample($0) }
                .map(\.departure).min()
        }
        public var comparedDepartures: (earlier: DepartureEstimate, later: DepartureEstimate)? {
            guard let model, let date = earlierDeparture,
                  let earlier = model.samples.first(where: { $0.departure == date }),
                  canUseSample(model.suggestion) else { return nil }
            return (earlier, model.suggestion)
        }
        /// The panel and widget lead with the policy's suggestion: meaningfully less driving
        /// inside the person's own limits. The earlier option stays one press away in the panel.
        public var preferredDeparture: DepartureEstimate? { model?.suggestion }
        public var capsuleDisabled: Bool { primaryAvailable.map { !$0 } ?? (state == .checking) }
        public var capsuleGreen: Bool { rows.first?.go == true }
        public var circleSymbol: String? {
            switch state {
            case .suggested: return "scope"
            case .watching: return phase == .missed ? nil : "plus"
            default: return nil
            }
        }
        public var circleDisabled: Bool {
            if state == .suggested { return true }
            if circleSymbol == "arrow.clockwise" { return !recheckAvailable }
            if circleSymbol == "plus", let delayAvailable { return !delayAvailable }
            guard circleSymbol == "plus", let committedDeparture else { return false }
            return phase == .leaveNow || committedDeparture.addingTimeInterval(300) > limits.latest
        }
        public var ticks: [Tick] {
            if state == .noRoute {
                return RulerModel.ticks(center: now, limits: limits, calendar: calendar, allDim: true)
            }
            if state == .checking && !checkingKeepsEvidence {
                let midpoint = limits.earliest.addingTimeInterval(limits.latest.timeIntervalSince(limits.earliest) / 2)
                return RulerModel.ticks(center: midpoint, limits: limits, calendar: calendar)
            }
            guard let model, let selectedIndex else { return [] }
            return RulerModel.ticks(center: model.samples[selectedIndex].departure, limits: limits, calendar: calendar)
        }
        public var bars: [SampleBar] {
            guard state != .noRoute, let model, let selectedIndex else { return [] }
            let midpoint = limits.earliest.addingTimeInterval(limits.latest.timeIntervalSince(limits.earliest) / 2)
            let center = state == .checking && !checkingKeepsEvidence ? midpoint : model.samples[selectedIndex].departure
            let offset = 180 - model.x(for: center)
            let bars = model.bars(offset: offset, state: checkingKeepsEvidence ? .stale : state, now: now, committedDeparture: committedDeparture)
            guard state == .checking else { return bars }
            let markers = checkingSamples.isEmpty ? Array(model.samples.prefix(receivedCount)) : checkingSamples
            let arrived = Set(markers.map(\.departure))
            let oldBars = checkingKeepsEvidence ? bars.filter { !arrived.contains(model.samples[$0.index].departure) } : []
            return oldBars + markers.enumerated().map { index, sample in
                let growing = index == receivedCount - 1
                return SampleBar(index: model.samples.firstIndex(of: sample) ?? model.samples.count + index,
                                 x: model.x(for: sample.departure, offset: offset),
                                 height: 20 * (growing ? newestBarProgress : 1), opacity: 0.6)
            }
        }
    }
}
