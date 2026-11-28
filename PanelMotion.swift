import Foundation

/// All WP7 timing lives here, shared by the running panel and fixed-time captures.
public enum PanelMotion {
    public static let roll = 0.26, word = 0.20, ui = 0.15, morph = 0.24
    public static let glide = 0.32, home = 0.36, settle = 0.42, grow = 0.24
    public static let pop = 0.30, washIn = 0.40, washOut = 0.30, dim = 0.30
    public static let hoverIn = 0.10, hoverOut = 0.15
    public static let openDuration = 0.12, closeDuration = 0.10
    public static let reducedFade = 0.12, reducedTravel = 0.15
    public static let textOut = 0.06, textIn = 0.12
    public static let settleDelay = 0.20, placeholderFade = textOut + textIn, barStagger = 0.016
    public static let feedbackHold = 3.0, inputLock = 0.60, previewHold = 0.90
    public static let projection = 0.10, maxTravel = 0.45, velocitySampleMaxAge = 0.08, scrollEndDelay = 0.14

    public static func textOpacities(at elapsed: Double) -> (old: Double, new: Double) {
        (1 - easeOut(elapsed / textOut), easeOut((elapsed - textOut) / textIn))
    }

    public static func easeInOut(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }
    public static func easeOut(_ progress: Double) -> Double {
        let p = min(1, max(0, progress)); return 1 - pow(1 - p, 3)
    }
}

/// A damped spring in absolute departure minutes. Retargeting preserves in-flight velocity.
public struct RulerMotion: Equatable {
    public private(set) var position: Double
    public private(set) var velocity: Double = 0
    public private(set) var target: Double
    public private(set) var isMoving = false
    private var origin: Double
    private var initialVelocity: Double = 0
    private var started: TimeInterval = 0
    private var response = PanelMotion.home
    private var damping = 1.0
    private var easeDuration: Double?

    public init(position: Double) { self.position = position; target = position; origin = position }
    public mutating func jump(to value: Double) {
        guard value.isFinite else { return }
        position = value; target = value; origin = value; velocity = 0; isMoving = false
    }
    public mutating func retarget(_ value: Double, at time: TimeInterval, response: Double,
                                 damping: Double = 0.9, reduced: Bool = false) {
        guard value.isFinite, time.isFinite, response > 0 else { return }
        advance(to: time)
        origin = position; initialVelocity = velocity; target = value; started = time
        self.response = response; self.damping = damping; easeDuration = reduced ? PanelMotion.reducedTravel : nil
        isMoving = abs(target - position) > 0.0001 || abs(velocity) > 0.0001
    }
    public mutating func ease(to value: Double, at time: TimeInterval, duration: Double) {
        retarget(value, at: time, response: duration, damping: 1)
        easeDuration = duration
    }
    public mutating func setVelocity(_ value: Double) { if value.isFinite { velocity = value } }
    public mutating func advance(to time: TimeInterval) {
        guard isMoving else { return }
        let t = max(0, time - started)
        let duration = easeDuration ?? (damping >= 1 ? PanelMotion.maxTravel : min(response, PanelMotion.maxTravel))
        if t >= duration { jump(to: target); return }
        if easeDuration != nil {
            position = origin + (target - origin) * PanelMotion.easeOut(t / duration)
            velocity = (target - origin) * 3 * pow(1 - t / duration, 2) / duration
            return
        }
        let w = 2 * Double.pi / response, y = origin - target, e = exp(-damping * w * t)
        if damping >= 1 {
            let b = initialVelocity + w * y
            position = target + (y + b * t) * e
            velocity = (b - w * (y + b * t)) * e
        } else {
            let wd = w * sqrt(1 - damping * damping), b = (initialVelocity + damping * w * y) / wd
            let c = cos(wd * t), s = sin(wd * t), z = y * c + b * s
            position = target + e * z
            velocity = e * (-damping * w * z + wd * (-y * s + b * c))
        }
    }
}

/// Publications from the clock or permission query cannot interrupt a pending settle.
public struct LandingState {
    public private(set) var isHolding = false
    public init() {}
    public mutating func receive(_ change: PanelChange) -> Bool {
        if isHolding && (change == .clockTick || change == .feedback || change == .batchSettled) { return true }
        isHolding = change == .batchSettled
        return false
    }
    public mutating func finish() { isHolding = false }

    /// SwiftUI evaluates body before onChange; stage the first landed render too.
    public func content(incoming: RulerModel.PanelSnapshot,
                        previous: RulerModel.PanelSnapshot?,
                        staged: RulerModel.PanelSnapshot?) -> RulerModel.PanelSnapshot {
        if let staged { return staged }
        if let previous, PanelChange.classify(previous: previous, next: incoming) == .batchSettled { return previous }
        return incoming
    }
}

public struct AnnouncementState {
    private var cause: PanelChange?
    private var text = ""
    public init() {}
    public mutating func receive(_ next: PanelChange) {
        if cause != next { text = ""; cause = next }
    }
    public mutating func accepts(_ value: String) -> Bool {
        guard value != text else { return false }
        text = value; return true
    }
}

public struct CapsuleState: Equatable {
    public private(set) var label = ""
    public private(set) var lockedUntil: TimeInterval = 0
    public init() {}
    public mutating func update(_ value: String, at time: TimeInterval, opened: Bool = false) {
        guard value != label else { return }
        if !label.isEmpty && !opened { lockedUntil = time + PanelMotion.inputLock }
        label = value
    }
    public func accepts(at time: TimeInterval) -> Bool { time >= lockedUntil }
    public static func returnMayActivate(_ label: String) -> Bool {
        label.hasPrefix("WATCH ") || label.hasPrefix("REVIEW ") || label == "CHECK TIMES" || label == "CHECK AGAIN" || label == "EDIT TIMES" || label == "SET ROUTE"
    }
}

public struct BarMotion: Equatable, Identifiable {
    public var id: Date { departure }
    public let departure: Date
    public var height: Double
    public var opacity: Double
    private var fromHeight: Double
    private var fromOpacity: Double
    private var toHeight: Double
    private var toOpacity: Double
    private var started: TimeInterval
    private var duration: Double
    private var dimming = false
    public private(set) var isMoving = false
    public init(departure: Date, height: Double, opacity: Double) {
        self.departure = departure; self.height = height; self.opacity = opacity
        fromHeight = height; toHeight = height; fromOpacity = opacity; toOpacity = opacity
        started = 0; duration = 0
    }
    public mutating func retarget(height: Double, opacity: Double, at time: TimeInterval,
                                  duration: Double, delay: Double = 0, reduced: Bool, dimming: Bool = false) {
        guard height != toHeight || opacity != toOpacity else { return }
        advance(to: time)
        fromHeight = reduced ? height : self.height; fromOpacity = self.opacity
        toHeight = height; toOpacity = opacity
        if reduced { self.height = height }
        started = time + (reduced ? 0 : delay); self.duration = reduced && !dimming ? PanelMotion.reducedFade : duration
        self.dimming = dimming
        isMoving = true
    }
    public mutating func advance(to time: TimeInterval) {
        guard isMoving else { return }
        let progress = (time - started) / duration
        let p = dimming ? PanelMotion.easeInOut(progress) : PanelMotion.easeOut(progress)
        height = fromHeight + (toHeight - fromHeight) * p
        opacity = fromOpacity + (toOpacity - fromOpacity) * p
        if time >= started + duration { height = toHeight; opacity = toOpacity; isMoving = false }
    }
}

/// The same scene is stepped by TimelineView and by the capture harness, without launching Window.
public struct RulerScene {
    public var ruler: RulerMotion
    public var band: RulerMotion
    public private(set) var bars: [BarMotion] = []
    public private(set) var retiringBars: [BarMotion] = []
    private var markerDepartures: Set<Date> = []
    public init(snapshot: RulerModel.PanelSnapshot) {
        let center = Self.center(snapshot).timeIntervalSinceReferenceDate / 60
        ruler = RulerMotion(position: center)
        band = RulerMotion(position: Self.suggestion(snapshot).timeIntervalSinceReferenceDate / 60)
        bars = Self.targets(snapshot).map { BarMotion(departure: $0.0, height: $0.1, opacity: $0.2) }
        markerDepartures = Self.markers(snapshot)
    }
    public var isMoving: Bool { ruler.isMoving || band.isMoving || bars.contains(where: \.isMoving) || retiringBars.contains(where: \.isMoving) }
    public mutating func advance(to time: TimeInterval) {
        ruler.advance(to: time); band.advance(to: time)
        for i in bars.indices { bars[i].advance(to: time) }
        bars.removeAll { !$0.isMoving && $0.opacity == 0 }
        for i in retiringBars.indices { retiringBars[i].advance(to: time) }
        retiringBars.removeAll { !$0.isMoving && $0.opacity == 0 }
    }
    public mutating func receive(_ snapshot: RulerModel.PanelSnapshot, change: PanelChange,
                                 at time: TimeInterval, previewing: Bool, reduced: Bool) {
        advance(to: time)
        let nextMarkers = Self.markers(snapshot)
        if snapshot.checkingKeepsEvidence {
            for departure in nextMarkers.subtracting(markerDepartures) {
                guard let index = bars.firstIndex(where: { $0.departure == departure }) else { continue }
                var evidence = bars.remove(at: index)
                evidence.retarget(height: evidence.height, opacity: 0, at: time, duration: PanelMotion.reducedFade, reduced: reduced)
                retiringBars.removeAll { $0.departure == departure }
                retiringBars.append(evidence)
            }
        }
        markerDepartures = nextMarkers
        let next = Self.targets(snapshot)
        let keys = Set(next.map { $0.0 })
        for i in bars.indices where !keys.contains(bars[i].departure) {
            bars[i].retarget(height: bars[i].height, opacity: 0, at: time, duration: PanelMotion.ui, reduced: false)
        }
        for (index, value) in next.enumerated() {
            let existing = bars.firstIndex { $0.departure == value.0 }
            let i = existing ?? bars.count
            if existing == nil { bars.append(BarMotion(departure: value.0, height: 0, opacity: 0)) }
            let delay = change == .batchSettled ? Double(index) * PanelMotion.barStagger : 0
            let duration = change == .paused || change == .phase ? PanelMotion.dim : PanelMotion.grow
            bars[i].retarget(height: value.1, opacity: value.2, at: time, duration: duration, delay: delay, reduced: reduced, dimming: change == .paused || change == .phase)
        }
        if !previewing && band == ruler && (change == .clockTick || change == .feedback || change == .checkingProgress) { return }
        let suggestion = Self.suggestion(snapshot).timeIntervalSinceReferenceDate / 60
        // The band can retarget without moving the time held under a pointer.
        if !previewing && change == .batchRefreshed {
            band.jump(to: suggestion)
        } else { band.ease(to: suggestion, at: time, duration: reduced ? PanelMotion.reducedFade : PanelMotion.grow) }
        guard !previewing else { return }
        switch change {
        case .checkingStarted where !snapshot.checkingKeepsEvidence:
            ruler.jump(to: Self.center(snapshot).timeIntervalSinceReferenceDate / 60)
            band.jump(to: ruler.position)
        case .paused, .resumed, .checkingStarted:
            ruler.retarget(Self.center(snapshot).timeIntervalSinceReferenceDate / 60,
                           at: time, response: PanelMotion.home, damping: 1, reduced: reduced)
            band = ruler
        case .batchSettled, .delayLanded, .ended, .batchRefreshed:
            let target = Self.center(snapshot).timeIntervalSinceReferenceDate / 60
            if change == .batchSettled && reduced { ruler.jump(to: target) }
            else { ruler.retarget(target, at: time, response: PanelMotion.settle, reduced: reduced) }
            if change == .batchSettled { band = ruler }
        case .commit:
            let target = Self.center(snapshot).timeIntervalSinceReferenceDate / 60
            if abs(ruler.position - target) > 0.0001 {
                ruler.retarget(target, at: time, response: PanelMotion.settle, reduced: reduced)
            }
        default: break
        }
    }
    public static func center(_ snapshot: RulerModel.PanelSnapshot) -> Date {
        if snapshot.state == .noRoute { return snapshot.now }
        if snapshot.state == .checking && !snapshot.checkingKeepsEvidence {
            return snapshot.limits.earliest.addingTimeInterval(snapshot.limits.latest.timeIntervalSince(snapshot.limits.earliest) / 2)
        }
        return snapshot.scrubModel?.suggestion.departure ?? snapshot.now
    }
    private static func suggestion(_ snapshot: RulerModel.PanelSnapshot) -> Date {
        if snapshot.state == .checking && !snapshot.checkingKeepsEvidence { return center(snapshot) }
        return snapshot.scrubModel?.suggestion.departure ?? center(snapshot)
    }
    private static func markers(_ snapshot: RulerModel.PanelSnapshot) -> Set<Date> {
        guard snapshot.state == .checking else { return [] }
        let samples = snapshot.checkingSamples.isEmpty ? Array((snapshot.model?.samples ?? []).prefix(snapshot.receivedCount)) : snapshot.checkingSamples
        return Set(samples.map(\.departure))
    }
    private static func targets(_ snapshot: RulerModel.PanelSnapshot) -> [(Date, Double, Double)] {
        guard let model = snapshot.model else { return [] }
        if snapshot.state == .checking {
            let markers = snapshot.checkingSamples.isEmpty ? Array(model.samples.prefix(snapshot.receivedCount)) : snapshot.checkingSamples
            let arrived = Set(markers.map(\.departure))
            let old = snapshot.checkingKeepsEvidence ? model.bars(state: .stale).filter {
                !arrived.contains(model.samples[$0.index].departure)
            }.map { (model.samples[$0.index].departure, $0.height, $0.opacity) } : []
            return old + markers.map { ($0.departure, 20.0, 0.6) }
        }
        return snapshot.bars.compactMap { bar in
            guard model.samples.indices.contains(bar.index) else { return nil }
            return (model.samples[bar.index].departure, bar.height, bar.opacity)
        }
    }
}
