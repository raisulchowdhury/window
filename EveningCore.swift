import Foundation

extension DeparturePolicy {
    /// Eight minutes is a product threshold, not a confidence interval. Within two
    /// minutes of the best checked drive, prefer the earlier departure.
    static func meaningfulDriving(_ samples: [DepartureEstimate]) -> DepartureEstimate? {
        let choices = samples.filter(\.valid).sorted { $0.departure < $1.departure }
        guard let first = choices.first, let shortest = choices.map(\.driving).min() else { return nil }
        guard first.driving - shortest >= 8 * 60 else { return first }
        return choices.first { first.driving - $0.driving >= 8 * 60 && $0.driving <= shortest + 2 * 60 }
    }
}

extension SavedJourney {
    func sameJourney(as other: SavedJourney) -> Bool {
        var lhs = self, rhs = other
        lhs.appearance = "System"; rhs.appearance = "System"
        return lhs == rhs
    }
}

/// A calendar-day identity rather than a fixed 24-hour lifetime. A timezone
/// change deliberately starts a new local-day context instead of moving a trip.
enum JourneyDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(calendar.identifier)|\(calendar.timeZone.identifier)|\(parts.era ?? 0)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

private struct DailyJourney: Codable {
    let day: String
    let journey: SavedJourney
}

extension JourneyStore {
    // Preserve the existing usual-journey key as the migration and rollback path.
    func loadToday(on date: Date) -> SavedJourney {
        let usual = load()
        guard let data = defaults.data(forKey: "window.live.today.v1"),
              let daily = try? JSONDecoder().decode(DailyJourney.self, from: data),
              daily.day == JourneyDay.key(date), daily.journey.valid,
              daily.journey.origin?.valid != false, daily.journey.destination?.valid != false else { return usual }
        var value = daily.journey
        value.appearance = usual.appearance
        return value
    }
    func saveToday(_ value: SavedJourney, on date: Date) {
        guard value.valid, value.origin?.valid != false, value.destination?.valid != false,
              let data = try? JSONEncoder().encode(DailyJourney(day: JourneyDay.key(date), journey: value)) else { return }
        defaults.set(data, forKey: "window.live.today.v1")
    }
}

/// Draft values never write through to storage. The revision also prevents an
/// editor in the menu panel from overwriting changes accepted in the main window.
struct JourneyEdit: Identifiable {
    let id = UUID()
    let day: String
    let revision: Int
    var value: SavedJourney
}

/// Freeze everything that is being compared while a person is deciding.
/// A refresh may invalidate this offer, but cannot change its displayed numbers.
struct DepartureOffer: Identifiable, Equatable {
    let id = UUID()
    let choice: DepartureEstimate
    let baseline: DepartureEstimate?
    let routeID: String
    let checkedAt: Date
    let limits: WatchLimits
    let recovery: Bool
    let requestedLimits: WatchLimits
    let session: UUID?

    init(choice: DepartureEstimate, baseline: DepartureEstimate?, batch: TrafficBatch,
         limits: WatchLimits, recovery: Bool = false, requestedLimits: WatchLimits? = nil, session: UUID? = nil) {
        self.choice = choice; self.baseline = baseline
        routeID = batch.routeID; checkedAt = batch.checkedAt
        self.limits = limits; self.recovery = recovery
        self.requestedLimits = requestedLimits ?? limits
        self.session = session
    }
    func matches(batch: TrafficBatch?, limits: WatchLimits?, at now: Date) -> Bool {
        guard let batch, let limits else { return false }
        return batch.isFresh(at: now) && batch.routeID == routeID && batch.checkedAt == checkedAt
            && self.limits == limits && batch.sample(at: choice.departure) == choice
            && choice.departure >= now && choice.valid
    }
}

/// A display clock, deliberately unrelated to civil time and departure scheduling.
/// Date is only the existing sampling API's carrier for monotonic uptime seconds.
enum WindowMotionClock {
    static var now: Date { Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime) }
}

/// Two cascaded first-order responses form a critically damped transition. Both
/// internal states stay inside the opacity gamut. Redirecting preserves value AND
/// velocity instead of restarting an easing curve with a zero initial slope.
struct DotMorph {
    private(set) var from: [Double] = []
    private(set) var target: [Double] = []
    private var driverFrom: [Double] = []
    private(set) var started = Date.distantPast
    private(set) var running = false
    private(set) var motionID: UUID?
    // Response is tuned for prompt feedback; duration bounds the remaining tail.
    // Even a full-range change has < 1/8192 opacity error at this cutoff.
    static let duration: TimeInterval = 0.42
    private static let response = 28.0

    private func elapsed(_ date: Date) -> TimeInterval {
        let value = date.timeIntervalSince(started)
        return value.isFinite ? max(0, value) : Self.duration
    }
    func values(at date: Date) -> [Double] {
        guard running, from.count == target.count else { return target }
        let t = elapsed(date)
        // Preserve the exact presented value on the redirect frame. Comparing
        // dates avoids cancellation error at the finite-tail deadline.
        guard date < started.addingTimeInterval(Self.duration) else { return target }
        if t == 0 { return from }
        let decay = exp(-Self.response * t)
        return target.indices.map { i in
            target[i] + ((from[i] - target[i]) + Self.response * (driverFrom[i] - target[i]) * t) * decay
        }
    }
    private func drivers(at date: Date) -> [Double] {
        guard running, date < started.addingTimeInterval(Self.duration) else { return target }
        if elapsed(date) == 0 { return driverFrom }
        let decay = exp(-Self.response * elapsed(date))
        return target.indices.map { target[$0] + (driverFrom[$0] - target[$0]) * decay }
    }
    mutating func move(to values: [Double], at date: Date, animated: Bool) {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        if animated, values == target {
            if date >= started.addingTimeInterval(Self.duration) { finish() }
            return // A duplicate target must not extend the transition or stop its velocity.
        }
        let visible = self.values(at: date), driver = drivers(at: date)
        let sameLayout = visible.count == values.count
        from = sameLayout ? visible : values
        driverFrom = sameLayout ? driver : values
        target = values; started = date
        running = animated && sameLayout && (from != target || driverFrom != target)
        motionID = running ? UUID() : nil
        if !running { from = target; driverFrom = target }
    }
    mutating func finish(_ id: UUID? = nil) {
        guard id == nil || id == motionID else { return }
        from = target; driverFrom = target; running = false; motionID = nil
    }
}

/// Accumulates trackpad movement; a wheel notch makes one bounded adjustment.
struct TimeScrollAccumulator {
    var remainder: CGFloat = 0
    var lastEvent: TimeInterval = 0
    mutating func steps(delta: CGFloat, precise: Bool, timestamp: TimeInterval) -> Int {
        guard delta.isFinite, timestamp.isFinite else { remainder = 0; return 0 }
        if timestamp < lastEvent || timestamp - lastEvent > 0.25 || remainder * delta < 0 { remainder = 0 }
        lastEvent = timestamp
        if !precise { return delta == 0 ? 0 : delta > 0 ? 1 : -1 }
        remainder = min(12_000, max(-12_000, remainder + delta))
        let count = Int(remainder / 12)
        remainder -= CGFloat(count) * 12
        return count
    }
    static func adjusted(_ value: Int, steps: Int, bounds: ClosedRange<Int>) -> Int {
        let base = min(bounds.upperBound, max(bounds.lowerBound, value))
        let (offset, multiplyOverflow) = steps.multipliedReportingOverflow(by: 5)
        if multiplyOverflow { return steps > 0 ? bounds.upperBound : bounds.lowerBound }
        let (sum, addOverflow) = base.addingReportingOverflow(offset)
        if addOverflow { return steps > 0 ? bounds.upperBound : bounds.lowerBound }
        return min(bounds.upperBound, max(bounds.lowerBound, sum))
    }
}

/// Keep corrupt preferences from producing invisible text or impossible layouts.
/// Bounds match Standard / Larger / Largest; this is not a 200% zoom claim.
enum WindowTextMetrics {
    static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(1.4, max(1, value))
    }
    static func editorWidth(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        base + (normalized(scale) - 1) * 200
    }
}

/// Estimates are approximate in both visible and spoken descriptions.
enum WindowCopy {
    static func minutes(_ count: Int) -> String { "\(count) \(count == 1 ? "minute" : "minutes")" }
    static func driving(_ estimate: DepartureEstimate) -> String {
        "About \(estimate.displayDrivingMinutes) min driving"
    }
    static func spokenDriving(_ estimate: DepartureEstimate) -> String {
        "About \(minutes(estimate.displayDrivingMinutes)) driving"
    }
    static func travelLine(_ estimate: DepartureEstimate) -> String {
        driving(estimate) + " · Arrive around " + { let c = Calendar.current.dateComponents([.hour, .minute], from: estimate.displayArrival); return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }()
    }
    static let preparationNote = "Time to finish up and reach your car. You’re notified to wrap up this many minutes before you leave, then again when it’s time to go."
    static let offerNeedsCheck = "This departure needs a fresh check before you choose it."
    static let monitoringLimits = "Window must be running, awake and online with fresh estimates. Focus and macOS settings can silence alerts."
    static let privacy = "Places and times stay on this Mac. Search text and route coordinates go to Apple Maps."
}


/// A nested editor may only commit into the exact parent draft that opened it.
/// Its owner also synchronizes the clock immediately before applying the value.
extension JourneyEdit {
    func acceptsChild(_ parentID: UUID?, day: String, revision: Int) -> Bool {
        id == parentID && self.day == day && self.revision == revision
    }
}

enum MinuteEntry {
    static func value(_ text: String, bounds: ClosedRange<Int> = 0...30) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), bounds.contains(value) else { return nil }
        return value
    }
    /// A 24-hour clock time typed by hand: "17:30", "7:05", "17.30" or "1730".
    /// Returns minutes after midnight, or nil for anything that is not a real time.
    static func clock(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hourText: Substring, minuteText: Substring
        if let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "." }) {
            hourText = trimmed[..<separator]; minuteText = trimmed[trimmed.index(after: separator)...]
        } else if trimmed.count == 3 || trimmed.count == 4 {
            let split = trimmed.index(trimmed.endIndex, offsetBy: -2)
            hourText = trimmed[..<split]; minuteText = trimmed[split...]
        } else { return nil }
        let digits: (Substring) -> Bool = { part in part.allSatisfy { $0.isASCII && $0.isNumber } }
        guard (1...2).contains(hourText.count), minuteText.count == 2, digits(hourText), digits(minuteText),
              let hour = Int(hourText), let minute = Int(minuteText),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
    /// The app's one clock: zero-padded 24-hour time.
    static func clockText(_ minutes: Int) -> String {
        let value = min(1439, max(0, minutes))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// One physical scroll gesture owns either the value or the page, never both.
/// Momentum after an owned gesture is swallowed without producing value edits.
struct ScrollEditSession {
    enum Phase { case discrete, began, changed, ended, cancelled, momentum }
    enum Decision: Equatable { case passThrough, consume, adjust }
    private enum State { case idle, armed, editing, settling }
    private var state = State.idle
    mutating func handle(_ phase: Phase, inside: Bool, enabled: Bool, vertical: Bool, stationary: Bool = false) -> Decision {
        guard inside && enabled else { state = .idle; return .passThrough }
        switch phase {
        case .began:
            if stationary { state = .armed; return .consume }
            state = vertical ? .editing : .idle
            return vertical ? .adjust : .passThrough
        case .changed:
            if state == .armed {
                if stationary { return .consume }
                state = vertical ? .editing : .idle
            }
            return state == .editing ? (vertical ? .adjust : .consume) : .passThrough
        case .ended:
            let owned = state == .editing || state == .armed
            state = owned ? .settling : .idle
            return owned ? .consume : .passThrough
        case .cancelled:
            let owned = state != .idle; state = .idle
            return owned ? .consume : .passThrough
        case .momentum:
            return state == .idle ? .passThrough : .consume
        case .discrete:
            state = .idle
            return vertical ? .adjust : .passThrough
        }
    }
}

/// Keyboard navigation stays inside the currently displayed result set.
enum ResultSelection {
    static func moved(_ selected: String?, in ids: [String], direction: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return direction < 0 ? ids.last : ids.first
        }
        return ids[min(ids.count - 1, max(0, index + (direction < 0 ? -1 : 1)))]
    }
}

/// Editing belongs to a surface. Closing the menu panel must not navigate or
/// discard an independent main-window draft sharing the same live controller.
enum JourneyPresentation {
    static func screen(model: String, editing: Bool) -> String {
        model == "finished" ? "finished" : editing ? "setup" : model
    }
}
