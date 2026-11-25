import Foundation

public struct TarasRulerModel {
    public enum State: Equatable { case noRoute, checking, suggested, watching, paused, stale, noFit }
    public enum Glyph: Equatable {
        case none, hour, ringO, orange, green, flat, down, check, checkDim, warn, red, pause, cross, dots
    }

    public struct Row: Equatable {
        public var label: String
        public var status: String
        public var glyph: Glyph
        public let name: String
        public let value: String
        public var anchor = false
        public var go = false
        public var dim = false
        public var nameDim = false
        public var valDim = false
    }

    public struct Tick: Equatable {
        public let date: Date
        public let x: Double
        public let isMajor: Bool
        public let dim: Bool
        public var height: Double { isMajor ? 30 : 15 }
    }

    public struct SampleBar: Equatable {
        public let index: Int
        public let x: Double
        public let height: Double
        public let opacity: Double
        public var dim: Bool { opacity < 1 }
    }

    public let batch: TrafficBatch
    public let limits: WatchLimits
    public let suggestionIndex: Int
    let comparisonBaseline: DepartureEstimate?
    let originalArrivalLimits: WatchLimits?
    public let calendar: Calendar
    public var samples: [DepartureEstimate] { batch.samples }
    public var suggestion: DepartureEstimate { samples[suggestionIndex] }
    public var minutesPerTick: Int {
        let minutes = limits.latest.timeIntervalSince(limits.earliest) / 60
        return [1, 2, 5].first { minutes / Double($0) * 6 <= 300 } ?? 5
    }
    public var majorTickMinutes: Int { minutesPerTick == 1 ? 15 : minutesPerTick == 2 ? 30 : 60 }
    public var pointsPerMinute: Double { 6 / Double(minutesPerTick) }

    /// Keep returned sample order (and indices); the core owns the recommendation.
    public init?(batch: TrafficBatch, limits: WatchLimits, suggestedDeparture: Date, calendar: Calendar = .current,
                 comparisonBaseline: DepartureEstimate? = nil, originalArrivalLimits: WatchLimits? = nil) {
        let window = limits.latest.timeIntervalSince(limits.earliest)
        guard window.isFinite, (0...10800).contains(window),
              limits.earliest.timeIntervalSinceReferenceDate.isFinite,
              limits.homeBy.timeIntervalSinceReferenceDate.isFinite,
              limits.packing.isFinite, limits.packing >= 0,
              limits.buffer.isFinite, limits.buffer >= 0,
              batch.samples.allSatisfy({ $0.valid && $0.departure.timeIntervalSinceReferenceDate.isFinite }),
              let index = batch.samples.firstIndex(where: { $0.departure == suggestedDeparture }) else { return nil }
        self.batch = batch
        self.limits = limits
        self.suggestionIndex = index
        self.calendar = calendar
        self.comparisonBaseline = comparisonBaseline
        self.originalArrivalLimits = originalArrivalLimits
    }

    public func x(for date: Date, offset: Double = 0) -> Double {
        180 + date.timeIntervalSince(suggestion.departure) / 60 * pointsPerMinute + offset
    }

    public func ticks(offset: Double = 0) -> [Tick] {
        Self.ticks(center: suggestion.departure, limits: limits, calendar: calendar, offset: offset)
    }

    /// Empty and checking panels have a clock axis before any recommendation exists.
    public static func ticks(center: Date, limits: WatchLimits, calendar: Calendar = .current,
                             offset: Double = 0, allDim: Bool = false, overscan: Double = 0) -> [Tick] {
        guard offset.isFinite, center.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let minutes = limits.latest.timeIntervalSince(limits.earliest) / 60
        let unit = Double([1, 2, 5].first { minutes / Double($0) * 6 <= 300 } ?? 5)
        let major = unit == 1 ? 15 : unit == 2 ? 30 : 60
        let pointsPerMinute = 6 / unit
        let midnight = calendar.startOfDay(for: center)
        let centerMinute = center.timeIntervalSince(midnight) / 60
        let first = ceil((centerMinute + (3 - overscan - 180 - offset) / pointsPerMinute) / unit) * unit
        let last = floor((centerMinute + (357 + overscan - 180 - offset) / pointsPerMinute) / unit) * unit
        return stride(from: first, through: last, by: unit).map { minute in
            let date = midnight.addingTimeInterval(minute * 60)
            let localMinute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            return Tick(date: date, x: 180 + date.timeIntervalSince(center) / 60 * pointsPerMinute + offset,
                        isMajor: localMinute % major == 0,
                        dim: allDim || date < limits.earliest || date > limits.latest)
        }
    }

    public func bars(offset: Double = 0, state: State = .suggested, now: Date? = nil,
              committedDeparture: Date? = nil) -> [SampleBar] {
        if state == .noRoute { return [] }
        let shortest = samples.map(\.driving).min()!
        let longest = samples.map(\.driving).max()!
        // Small changes should not look as large as the eight-minute meaningful difference.
        let scale = 30 / max(480, longest - shortest)
        let missed = state == .watching && now.map { date in
            committedDeparture.map { date >= $0.addingTimeInterval(60) } ?? false
        } == true
        let dimmed = state == .paused || state == .stale || missed
        return samples.enumerated().map { index, sample in
            SampleBar(index: index, x: x(for: sample.departure, offset: offset),
                      height: 20 + scale * (sample.driving - shortest),
                      opacity: dimmed ? 0.3 : limits.fits(sample) ? 1 : 0.35)
        }
    }

    public func offset(forSampleAt index: Int) -> Double? {
        guard samples.indices.contains(index) else { return nil }
        return suggestion.departure.timeIntervalSince(samples[index].departure) / 60 * pointsPerMinute
    }

    /// Strict comparison preserves the first returned sample on a distance tie.
    public func nearestSampleIndex(offset: Double) -> Int {
        let target = suggestion.departure.addingTimeInterval(-offset / pointsPerMinute * 60)
        return samples.indices.reduce(0) { best, index in
            abs(samples[index].departure.timeIntervalSince(target)) < abs(samples[best].departure.timeIntervalSince(target)) ? index : best
        }
    }

    public func rubberBand(offset: Double) -> Double {
        let bounds = samples.indices.compactMap { self.offset(forSampleAt: $0) }
        let low = bounds.min()!, high = bounds.max()!
        if offset < low { return low - min(24, (low - offset) * 0.35) }
        if offset > high { return high + min(24, (offset - high) * 0.35) }
        return offset
    }

    /// Nil leaves the press a click; once dragging, crossing back into slop still moves.
    public func dragOffset(translation: Double, from startOffset: Double = 0, hasMoved: Bool = false) -> Double? {
        guard hasMoved || abs(translation) >= 3 else { return nil }
        return rubberBand(offset: startOffset + translation)
    }

    public func bandSpan(offset: Double) -> ClosedRange<Double>? {
        guard abs(offset) > 0.5 else { return nil }
        return min(180, 180 + offset)...max(180, 180 + offset)
    }

    public func headerText(offset: Double, parked: Bool = false) -> String {
        if offset == 0 && !parked { return "SUGGESTED" }
        let selected = samples[nearestSampleIndex(offset: offset)]
        return signedMinutes(selected.departure.timeIntervalSince(suggestion.departure))
    }

    /// No returned sample or suggestion is needed before the first completed batch.
    public static func placeholderRows(state: State, limits: WatchLimits, calendar: Calendar = .current) -> [Row] {
        guard state == .noRoute || state == .checking else { return [] }
        let checking = state == .checking
        let packing = Int(ceil(limits.packing / 60))
        return [
            Row(label: checking ? "WINDOW \(time(limits.earliest, calendar: calendar))–\(time(limits.latest, calendar: calendar))" : "SET A ROUTE TO BEGIN",
                status: checking ? "CHECKING" : "", glyph: checking ? .dots : .none,
                name: "Leave", value: checking ? "––:––" : "—", anchor: true, valDim: true),
            limits.packing == 0
                ? Row(label: "NO WRAP-UP TIME SET", status: "NOT NEEDED", glyph: .flat, name: "Wrap up", value: "—", valDim: true)
                : Row(label: checking ? "−\(packing)M · WRAP-UP TIME" : "WRAP-UP TIME", status: "", glyph: .none,
                      name: "Wrap up", value: checking ? "––:––" : "\(packing) min", valDim: true),
            Row(label: "APPLE MAPS", status: "", glyph: .none, name: "Drive", value: checking ? "–– min" : "—", valDim: true),
            Row(label: "ARRIVE BY \(time(limits.homeBy, calendar: calendar))", status: "", glyph: .none,
                name: "Arrive around", value: checking ? "––:––" : "—", valDim: true)
        ]
    }

    /// The controller supplies freshness/connectivity and the actual commitment; scrubs remain previews.
    public func rows(at index: Int, now: Date, state: State = .suggested,
              committedDeparture: Date? = nil, preparationAlreadyUnderway: Bool = false, keepBright: Bool = false,
              alertsOff: Bool = false) -> [Row] {
        if state == .noRoute || state == .checking {
            return Self.placeholderRows(state: state, limits: limits, calendar: calendar)
        }
        guard samples.indices.contains(index) else { return [] }
        let sample = samples[index]
        let baseline = comparisonBaseline ?? samples.filter(limits.fits).min { $0.departure < $1.departure }
            ?? samples.min { $0.departure < $1.departure }!
        let earliest = sample.departure == baseline.departure
        let wrap = sample.departure.addingTimeInterval(-limits.packing)
        let difference = baseline.driving - sample.driving
        let arrivalLimits = originalArrivalLimits ?? limits
        let spare = arrivalLimits.homeBy.timeIntervalSince(sample.arrival)
        let vs = " VS \(time(baseline.departure))"
        let packing = Int(ceil(limits.packing / 60))
        let arrivalDelta = Int((sample.arrival.timeIntervalSince(baseline.arrival) / 60).rounded())
        let arrivalComparison = arrivalDelta == 0 ? "SAME ARRIVAL" : "\(abs(arrivalDelta))M \(arrivalDelta > 0 ? "LATER" : "EARLIER")"
        let wait = sample.departure.timeIntervalSince(now)
        var result = [
            Row(label: earliest ? "EARLIEST CHECKED" : signedMinutes(sample.departure.timeIntervalSince(baseline.departure)) + vs,
                status: wait > 0 ? "WAIT \(Int(ceil(wait / 60)))M" : wait > -60 ? "NOW" : "PASSED",
                glyph: wait > 0 ? .hour : wait > -60 ? .flat : .cross,
                name: "Leave", value: time(sample.departure), anchor: true),
            limits.packing == 0
                ? Row(label: "NO WRAP-UP TIME SET", status: "NOT NEEDED", glyph: .flat, name: "Wrap up", value: "—", valDim: true)
                : Row(label: "−\(packing)M · WRAP-UP TIME",
                      status: wrap > now ? "IN \(Int(ceil(wrap.timeIntervalSince(now) / 60)))M" : "WRAP UP NOW",
                      glyph: wrap > now ? .ringO : .orange, name: "Wrap up", value: time(wrap)),
            Row(label: "APPLE MAPS",
                status: difference >= 480 ? "\(Int((difference / 60).rounded()))M LESS DRIVING" : sample.driving == samples.map(\.driving).max()! ? "LONGEST DRIVE" : "SIMILAR",
                glyph: difference >= 480 ? .down : .flat, name: "Drive", value: "\(sample.displayDrivingMinutes) min"),
            Row(label: (earliest ? "" : arrivalComparison + " · ") + "ARRIVE BY \(time(arrivalLimits.homeBy))",
                status: spare >= arrivalLimits.buffer ? "\(Int((spare / 60).rounded()))M SPARE" : spare >= 0 ? "INSIDE CUSHION" : "LATE \(Int(ceil(-spare / 60)))M",
                glyph: spare >= arrivalLimits.buffer ? .check : spare >= 0 ? .warn : .red,
                name: "Arrive around", value: time(sample.displayArrival))
        ]
        let recovery = state == .noFit && index == suggestionIndex
        if !limits.fits(sample) && !keepBright && !recovery {
            for i in result.indices { result[i].valDim = true }
        }
        switch state {
        case .suggested:
            break
        case .noRoute, .checking:
            break
        case .noFit:
            guard recovery else { break }
            result[0].label = "BEST CHECKED ARRIVAL"
            result[2].label = "APPLE MAPS"
            if sample.driving == samples.map(\.driving).min()! {
                result[2].status = "SHORTEST"; result[2].glyph = .flat
            }
            result[3].label = "ARRIVE BY \(time(limits.homeBy))"
        case .paused, .stale:
            result[0].status = "UNCONFIRMED"; result[0].glyph = .pause
            // A paused watch sends no wrap-up or leave alerts; macOS alerts may also be off.
            // Without a watch and with alerts allowed, nothing is silenced, so say nothing.
            let silenced = alertsOff || committedDeparture != nil
            result[1].status = silenced ? "ALERTS OFF" : limits.packing == 0 ? "NOT NEEDED" : ""
            result[1].glyph = silenced || limits.packing == 0 ? .flat : .none
            result[2].label = state == .stale ? "AS OF \(time(batch.checkedAt)) · EXPIRED" : "LAST CHECK \(time(batch.checkedAt))"
            result[2].status = ""; result[2].glyph = .none
            result[3].status = ""; result[3].glyph = .none
            for i in result.indices { result[i].valDim = true }
        case .watching:
            guard sample.departure == committedDeparture else {
                result[0].status = "PREVIEW"; result[0].glyph = .none
                if limits.packing > 0 { result[1].status = "PREVIEW"; result[1].glyph = .none }
                break
            }
            switch DepartureCuePhase.resolve(now: now, departure: sample.departure, packing: limits.packing,
                                            preparationAlreadyUnderway: preparationAlreadyUnderway) {
            case .waiting:
                break
            case .wrappingUp:
                if limits.packing > 0 { result[1].status = "WRAP UP NOW"; result[1].glyph = .orange }
            case .leaveNow:
                result[0].status = "LEAVE NOW"; result[0].glyph = .green; result[0].go = true
                if limits.packing > 0 {
                    result[1].status = "DONE"; result[1].glyph = .checkDim; result[1].valDim = true
                }
            case .missed:
                result[0].label = "DEPARTURE TIME PASSED"; result[0].status = "PASSED"; result[0].glyph = .cross
                if limits.packing > 0 { result[1].status = "DONE"; result[1].glyph = .checkDim }
                result[2].label = "APPLE MAPS"; result[2].status = ""; result[2].glyph = .none
                result[3].label = "ARRIVE BY \(time(limits.homeBy))"; result[3].status = ""; result[3].glyph = .none
                for i in result.indices { result[i].valDim = true }
            }
        }
        return result
    }

    /// Rows for the recovery review window, in the panel's words and 24-hour times.
    /// Status words match the Arrive around row ("NM SPARE", "LATE NM"); less spare than
    /// usual warns, and red stays reserved for LATE.
    public static func recoveryRows(for choice: DepartureEstimate, original: WatchLimits,
                                    calendar: Calendar = .current) -> [Row] {
        let spare = original.homeBy.timeIntervalSince(choice.arrival)
        let afterLimit = choice.departure > original.latest
        return [
            Row(label: afterLimit ? "AFTER YOUR \(time(original.latest, calendar: calendar)) LIMIT" : "BEST LEAVE TIME",
                status: "", glyph: .none, name: "Leave", value: time(choice.departure, calendar: calendar), anchor: true),
            Row(label: "APPLE MAPS", status: "", glyph: .none, name: "Drive", value: "\(choice.displayDrivingMinutes) min"),
            Row(label: "ARRIVE BY \(time(original.homeBy, calendar: calendar))",
                status: spare >= 0 ? "\(Int((spare / 60).rounded()))M SPARE" : "LATE \(Int(ceil(-spare / 60)))M",
                glyph: spare >= original.buffer ? .check : spare >= 0 ? .warn : .red,
                name: "Arrive around", value: time(choice.displayArrival, calendar: calendar))
        ]
    }

    private func time(_ date: Date) -> String {
        Self.time(date, calendar: calendar)
    }

    public static func time(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    private func signedMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes > 0 ? "+\(minutes)M" : minutes < 0 ? "−\(-minutes)M" : "±0M"
    }
}
