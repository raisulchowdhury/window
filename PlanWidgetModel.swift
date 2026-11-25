import Foundation

public struct PlanWidgetModel {
    public enum State { case noPlan, suggested, watching, paused, stale, missed }
    public let state: State
    public let panel: TarasRulerModel.PanelSnapshot?
    public let snapshot: PlanSnapshot?
    public let calendar: Calendar
    public var rows: [TarasRulerModel.Row] { panel?.rows ?? [] }
    public var dim: Bool { state != .watching }
    public var alertsOff: Bool { state == .watching && snapshot?.alertStatus != .allowed }
    public var departure: String { rows.first?.value ?? "—" }
    public var wrapUp: String { rows.dropFirst().first?.value ?? "—" }
    public var arrival: String { rows.last?.value ?? "—" }
    public var driveMinutes: Int { selectedSample?.displayDrivingMinutes ?? 0 }
    public var selectedSample: DepartureEstimate? {
        guard let snapshot else { return nil }
        let date = snapshot.committedDeparture ?? snapshot.suggestedDeparture
        return snapshot.samples.first { $0.departure == date }
    }
    public var phaseWord: String {
        switch state {
        case .noPlan: return "CHECK IN MENU BAR"
        case .suggested: return "NOT WATCHING"
        case .paused: return "OPEN WINDOW"
        case .stale: return "CHECK EXPIRED"
        case .missed: return "CHECK PLAN"
        case .watching: return alertsOff ? "ALERTS OFF" : "AS OF \(time(snapshot!.checkedAt))"
        }
    }
    public var phaseGlyph: TarasRulerModel.Glyph {
        return state == .paused || state == .stale ? .pause : state == .missed ? .cross : .none
    }
    public var headerLeft: String {
        switch state {
        case .noPlan: return "NO PLAN"
        case .suggested: return "SUGGESTED"
        case .paused: return "PAUSED"
        case .stale: return "AS OF \(time(snapshot!.checkedAt))"
        case .watching, .missed: return "LEAVE · \(snapshot!.routeLabel.uppercased())"
        }
    }
    public var smallHeader: String {
        switch state {
        case .watching: return "LEAVE AT"
        case .missed: return "DEPARTURE PASSED"
        default: return headerLeft
        }
    }
    public var smallFooter: String {
        state == .suggested || state == .watching ? "\(driveMinutes)M · ARRIVAL \(arrival)" : footer
    }
    public var footer: String {
        switch state {
        case .noPlan: return "CHECK IN MENU BAR"
        case .paused, .stale, .missed: return "OPEN WINDOW TO RECHECK"
        case .suggested, .watching: return "DRIVE \(driveMinutes)M · ARRIVAL \(arrival)"
        }
    }
    public var mediumHeaderLeft: String {
        state == .watching || state == .missed ? snapshot!.routeLabel.uppercased() : headerLeft
    }
    public var mediumHeaderRight: String {
        state == .missed ? "DEPARTURE PASSED" : phaseWord
    }
    public var leaveLabel: String {
        switch state {
        case .suggested, .watching: return "LEAVE AT"
        default: return "LAST DEPARTURE"
        }
    }
    public var wrapLabel: String {
        snapshot?.limits.packing == 0 ? "NOT NEEDED" : "WRAP UP"
    }
    public func time(_ date: Date) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    public init(entry: PlanWidgetEntry, calendar: Calendar = .current) {
        self.calendar = calendar
        snapshot = entry.snapshot
        guard let snapshot = entry.snapshot, snapshot.state != .idle,
              let suggestion = snapshot.suggestedDeparture,
              let model = TarasRulerModel(batch: TrafficBatch(routeID: snapshot.routeLabel, checkedAt: snapshot.checkedAt, samples: snapshot.samples),
                                         limits: snapshot.limits, suggestedDeparture: suggestion, calendar: calendar) else {
            state = .noPlan; panel = nil; return
        }
        let panelState: TarasRulerModel.State
        if entry.date >= snapshot.expiresAt || entry.date < snapshot.checkedAt.addingTimeInterval(-1) {
            state = .stale; panelState = .stale
        } else if snapshot.state == .paused {
            state = .paused; panelState = .paused
        } else if snapshot.state == .watching, let departure = snapshot.committedDeparture {
            state = entry.date >= departure.addingTimeInterval(60) ? .missed : .watching
            panelState = .watching
        } else {
            state = .suggested; panelState = .suggested
        }
        panel = TarasRulerModel.PanelSnapshot(state: panelState, limits: snapshot.limits, now: entry.date,
                                             calendar: calendar, model: model, routeTitle: snapshot.routeLabel,
                                             committedDeparture: snapshot.committedDeparture)
    }
}

extension TarasRulerModel {
    public struct MiniRuler {
        public let ticks: [Tick]
        public let bars: [SampleBar]
        public let cursorX: Double
    }

    /// Section 4's minute axis stays fixed around the selected departure, even for a three-hour plan.
    public func miniRuler(width: Double, height: Double, small: Bool, center: Date, dim: Bool) -> MiniRuler {
        let before = small ? 38 : 44
        let span = small ? 56 : 68
        let start = center.addingTimeInterval(Double(-before * 60))
        let scale = width / Double(span)
        let ticks = (0...span).map { minute in
            let date = start.addingTimeInterval(Double(minute * 60))
            let major = calendar.component(.minute, from: date) % 15 == 0
            return Tick(date: date, x: Double(minute) * scale, isMajor: major,
                        dim: date < limits.earliest || date > limits.latest)
        }
        let bars = bars(state: dim ? .stale : .watching).map { bar in
            SampleBar(index: bar.index, x: samples[bar.index].departure.timeIntervalSince(start) / 60 * scale,
                      height: height * (0.32 + 0.55 * (bar.height - 20) / 30), opacity: bar.opacity)
        }
        return MiniRuler(ticks: ticks, bars: bars, cursorX: Double(before) * scale)
    }
}
