import Foundation

public enum PlanWidgetFixtures {
    public static let states = ["watching", "wrap-up", "leave-now", "missed", "suggested", "stale", "paused", "no-plan", "no-wrap-up", "alerts-denied", "long-route-countdown"]
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    public static var all: [(name: String, entry: PlanWidgetEntry)] {
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        return states.map { (name: String) -> (name: String, entry: PlanWidgetEntry) in
            let early = name == "watching" || name == "no-wrap-up"
            let minutes: Double = early ? 1038 : 1042 // 17:18 or 17:22
            let now: Date = day.addingTimeInterval(minutes * 60)
            let snapshot: PlanSnapshot = try! make(state: name, now: now)
            return (name: name, entry: PlanWidgetEntry(date: now, snapshot: snapshot))
        }
    }

    /// Relative times keep launch-argument fixtures fresh on the real desktop.
    public static func make(state name: String, now: Date = .now) throws -> PlanSnapshot {
        guard states.contains(name) else {
            throw NSError(domain: "WindowFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown widget fixture: \(name). Use \(states.joined(separator: ", "))."])
        }
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let offset: Double = name == "leave-now" ? 0 : name == "missed" ? -1 : name == "long-route-countdown" ? 147 : name == "watching" || name == "no-wrap-up" ? 12 : 8
        let departure = minute.addingTimeInterval(offset * 60)
        let checkedAt = name == "stale" ? minute.addingTimeInterval(-20 * 60) : now
        let limits = WatchLimits(earliest: departure.addingTimeInterval(-20 * 60), latest: departure.addingTimeInterval(10 * 60),
                                 homeBy: departure.addingTimeInterval((name == "long-route-countdown" ? 75 : 45) * 60), packing: name == "no-wrap-up" ? 0 : 600)
        let samples = [41, 40, 37, 33, 31, 30, 30].enumerated().map {
            DepartureEstimate(departure: limits.earliest.addingTimeInterval(Double($0.offset * 5 * 60)), driving: Double((name == "long-route-countdown" ? 54 : $0.element) * 60))
        }
        let state: PlanSnapshot.State = name == "no-plan" ? .idle : name == "suggested" ? .suggested : name == "paused" ? .paused : .watching
        return try PlanSnapshot(routeLabel: name == "long-route-countdown" ? "North Campus → Harbor Terminal" : "Office → Home", limits: limits, samples: state == .idle ? [] : samples,
                                suggestedDeparture: state == .idle ? nil : departure,
                                committedDeparture: state == .idle || state == .suggested ? nil : departure,
                                checkedAt: checkedAt, state: state, alertStatus: name == "alerts-denied" ? .denied : .allowed)
    }
}
