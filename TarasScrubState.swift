import Foundation

/// Interaction only: offsets move continuously; every displayed value is a returned sample.
public struct TarasScrubState: Equatable {
    public enum Event {
        case press(x: Double, y: Double, presentedOffset: Double? = nil), drag(Double), release, releaseProjected(Double), cancel
        case park(Int), step(Int), edge(Bool), escape, home, use
    }
    public enum Effect: Equatable { case none, direct, park, home, use(Int) }
    public private(set) var offset: Double = 0
    public private(set) var parkedIndex: Int?
    public private(set) var isDragging = false
    public private(set) var hasMoved = false
    private var startOffset: Double = 0
    private var pressedBar: Int?

    public init() {}
    public var isPreviewing: Bool { offset != 0 || hasMoved || parkedIndex != nil }
    public func selectedIndex(in model: TarasRulerModel) -> Int {
        model.nearestSampleIndex(offset: offset)
    }

    @discardableResult
    public mutating func send(_ event: Event, model: TarasRulerModel) -> Effect {
        switch event {
        case let .press(x, y, presentedOffset):
            guard x.isFinite, y.isFinite else { return .none }
            if let presentedOffset, presentedOffset.isFinite { offset = presentedOffset }
            isDragging = true; hasMoved = false; startOffset = offset
            // Match the reference's 14 pt hit strip above each bar.
            pressedBar = model.bars(offset: offset).filter {
                abs($0.x - x) <= 6 && y >= 77 - $0.height && y <= 85
            }.min { abs($0.x - x) < abs($1.x - x) }?.index
            return .none
        case let .drag(translation):
            guard isDragging, translation.isFinite,
                  let next = model.dragOffset(translation: translation, from: startOffset, hasMoved: hasMoved) else { return .none }
            hasMoved = true; parkedIndex = nil; offset = next
            return .direct
        case let .releaseProjected(velocity):
            guard isDragging, velocity.isFinite else { return .none }
            if hasMoved {
                isDragging = false
                return send(.park(model.nearestSampleIndex(offset: offset + velocity * TarasMotion.projection)), model: model)
            }
            return send(.release, model: model)
        case .release:
            guard isDragging else { return .none }
            isDragging = false
            if hasMoved { return send(.park(selectedIndex(in: model)), model: model) }
            if let pressedBar { return send(.park(pressedBar), model: model) }
            return .none
        case .cancel:
            return send(.home, model: model)
        case let .park(index):
            guard let target = model.offset(forSampleAt: index) else { return .none }
            offset = target; parkedIndex = index; hasMoved = false; isDragging = false
            return .park
        case let .step(direction):
            guard direction != 0 else { return .none }
            let base = parkedIndex ?? model.suggestionIndex
            return send(.park(min(max(base + (direction > 0 ? 1 : -1), 0), model.samples.count - 1)), model: model)
        case let .edge(last):
            return send(.park(last ? model.samples.count - 1 : 0), model: model)
        case .escape:
            return isPreviewing ? send(.home, model: model) : .none
        case .home:
            self = Self()
            return .home
        case .use:
            let index = selectedIndex(in: model)
            return model.limits.fits(model.samples[index]) ? .use(index) : .none
        }
    }

    /// Rebase the gesture's coordinate system, never its absolute departure time.
    @discardableResult
    public mutating func rebase(from old: TarasRulerModel, to new: TarasRulerModel) -> Bool {
        let cursor = old.suggestion.departure.addingTimeInterval(-offset / old.pointsPerMinute * 60)
        let start = old.suggestion.departure.addingTimeInterval(-startOffset / old.pointsPerMinute * 60)
        offset = new.suggestion.departure.timeIntervalSince(cursor) / 60 * new.pointsPerMinute
        startOffset = new.suggestion.departure.timeIntervalSince(start) / 60 * new.pointsPerMinute
        guard let parkedIndex else { return false }
        let departure = old.samples[parkedIndex].departure
        let index = new.samples.firstIndex { $0.departure == departure } ?? new.nearestSampleIndex(offset: offset)
        self.parkedIndex = index
        offset = new.offset(forSampleAt: index)!
        return new.samples[index].departure != departure
    }

    public func escapeReturnsHome(canScrub: Bool) -> Bool { canScrub && (isPreviewing || isDragging) }

    public mutating func clearParkKeepingPosition() {
        parkedIndex = nil; isDragging = false; hasMoved = offset != 0
    }

    public func accessibilityValue(in model: TarasRulerModel, now: Date, committed: Bool = false) -> String {
        let index = selectedIndex(in: model)
        let rows = model.rows(at: index, now: now)
        let reference = committed ? "watched" : "suggested"
        let status = index == model.suggestionIndex ? ", \(reference)" : ""
        let minutes = model.samples[index].displayDrivingMinutes
        let offset = Int((model.samples[index].departure.timeIntervalSince(model.suggestion.departure) / 60).rounded())
        let comparison = offset == 0 ? "" : " \(abs(offset)) \(abs(offset) == 1 ? "minute" : "minutes") \(offset > 0 ? "later" : "earlier") than \(reference)."
        return "Departure \(rows[0].value)\(status). \(minutes) \(minutes == 1 ? "minute" : "minutes") driving, arrive around \(rows[3].value)." + comparison
    }
}
