import Foundation

/// The complete widget input. Only checked samples cross the app-group boundary.
public struct PlanSnapshot: Codable, Equatable {
    public enum State: String, Codable { case idle, suggested, watching, paused }
    public enum AlertStatus: String, Codable { case unknown, allowed, denied, unavailable, failed }
    public static let currentVersion = 1
    public let version: Int
    public let routeLabel: String
    public let limits: WatchLimits
    public let samples: [DepartureEstimate]
    public let suggestedDeparture: Date?
    public let committedDeparture: Date?
    public let checkedAt: Date
    public let expiresAt: Date
    public let state: State
    public let alertStatus: AlertStatus

    public init(version: Int = currentVersion, routeLabel: String, limits: WatchLimits,
                samples: [DepartureEstimate], suggestedDeparture: Date?, committedDeparture: Date?,
                checkedAt: Date, expiresAt: Date? = nil, state: State, alertStatus: AlertStatus) throws {
        self.version = version; self.routeLabel = routeLabel; self.limits = limits; self.samples = samples
        self.suggestedDeparture = suggestedDeparture; self.committedDeparture = committedDeparture
        self.checkedAt = checkedAt; self.expiresAt = expiresAt ?? checkedAt.addingTimeInterval(300)
        self.state = state; self.alertStatus = alertStatus
        let dates = [limits.earliest, limits.latest, limits.homeBy, checkedAt, self.expiresAt]
            + samples.map(\.departure) + [suggestedDeparture, committedDeparture].compactMap { $0 }
        guard version == Self.currentVersion, samples.count <= 12,
              dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
              limits.packing.isFinite, limits.packing >= 0, limits.buffer.isFinite, limits.buffer >= 0,
              (0...10800).contains(limits.latest.timeIntervalSince(limits.earliest)),
              limits.homeBy > limits.latest, samples.allSatisfy(\.valid),
              Set(samples.map(\.departure)).count == samples.count,
              self.expiresAt > checkedAt, self.expiresAt <= checkedAt.addingTimeInterval(300),
              suggestedDeparture.map({ date in samples.contains { $0.departure == date } }) ?? (state == .idle),
              committedDeparture.map({ date in samples.contains { $0.departure == date } }) ?? (state != .watching),
              state != .suggested || committedDeparture == nil,
              state != .watching || samples.contains(where: { $0.departure == committedDeparture && limits.fits($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Window plan snapshot"))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, routeLabel, limits, samples, suggestedDeparture, committedDeparture, checkedAt, expiresAt, state, alertStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(Int.self, forKey: .version), routeLabel: c.decode(String.self, forKey: .routeLabel),
                      limits: c.decode(WatchLimits.self, forKey: .limits), samples: c.decode([DepartureEstimate].self, forKey: .samples),
                      suggestedDeparture: c.decodeIfPresent(Date.self, forKey: .suggestedDeparture),
                      committedDeparture: c.decodeIfPresent(Date.self, forKey: .committedDeparture),
                      checkedAt: c.decode(Date.self, forKey: .checkedAt), expiresAt: c.decode(Date.self, forKey: .expiresAt),
                      state: c.decode(State.self, forKey: .state), alertStatus: c.decode(AlertStatus.self, forKey: .alertStatus))
    }
}

public struct PlanWidgetEntry {
    public let date: Date
    public let snapshot: PlanSnapshot?
    public init(date: Date, snapshot: PlanSnapshot?) { self.date = date; self.snapshot = snapshot }
}

public enum PlanWidgetTimeline {
    /// Expiry is terminal: subsequent phase boundaries must never revive an old plan.
    public static func entries(snapshot: PlanSnapshot?, now: Date) -> [PlanWidgetEntry] {
        guard let snapshot, snapshot.state != .idle, snapshot.expiresAt > now,
              now >= snapshot.checkedAt.addingTimeInterval(-1) else {
            return [PlanWidgetEntry(date: now, snapshot: snapshot)]
        }
        // WidgetKit may display a timeline entry late. Only the app gives live departure cues.
        let missed = snapshot.committedDeparture?.addingTimeInterval(60)
        let dates = [now, missed.flatMap { $0 > now && $0 < snapshot.expiresAt ? $0 : nil }, snapshot.expiresAt]
        return dates.compactMap { $0 }.map { PlanWidgetEntry(date: $0, snapshot: snapshot) }
    }
}

public enum PlanSnapshotStore {
    public static let key = "window.widget.snapshot.v1"

    public static func read(from defaults: UserDefaults) -> PlanSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlanSnapshot.self, from: data)
    }

    @discardableResult
    public static func write(_ snapshot: PlanSnapshot, to defaults: UserDefaults) throws -> Bool {
        guard read(from: defaults) != snapshot else { return false }
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: key)
        return true
    }
}
