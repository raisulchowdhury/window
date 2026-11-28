import Foundation

@MainActor
public enum PanelFixtures {
    public static let all: [(name: String, snapshot: RulerModel.PanelSnapshot)] = makeAll()
    public static var noJourney: RulerModel.PanelSnapshot { all[0].snapshot }

    private static func makeAll() -> [(name: String, snapshot: RulerModel.PanelSnapshot)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        func time(_ hour: Int, _ minute: Int) -> Date { day.addingTimeInterval(Double(hour * 60 + minute) * 60) }
        let now = time(16, 58)
        let limits = WatchLimits(earliest: time(17, 10), latest: time(17, 40), homeBy: time(18, 15), packing: 600)
        let samples = [41, 40, 37, 33, 31, 30, 30].enumerated().map {
            DepartureEstimate(departure: time(17, 10 + $0.offset * 5), driving: Double($0.element * 60))
        }
        func model(_ limits: WatchLimits, _ samples: [DepartureEstimate], checkedAt: Date) -> RulerModel {
            let departure = DeparturePolicy.recommend(samples, limits: limits, now: checkedAt, committed: nil)
                ?? DeparturePolicy.earliestArrival(samples)!
            return RulerModel(batch: TrafficBatch(routeID: "office-home", checkedAt: checkedAt, samples: samples),
                                   limits: limits, suggestedDeparture: departure.departure, calendar: calendar)!
        }
        let suggested = model(limits, samples, checkedAt: now)
        func snapshot(_ state: RulerModel.State, _ date: Date, _ model: RulerModel? = nil,
                      committed: Bool = false) -> RulerModel.PanelSnapshot {
            RulerModel.PanelSnapshot(state: state, limits: model?.limits ?? limits, now: date, calendar: calendar,
                                         model: model, routeTitle: "Office → Home",
                                         committedDeparture: committed ? model?.suggestion.departure : nil)
        }
        // A refreshed batch keeps the same core-approved commitment during later phase fixtures.
        func watching(_ date: Date, packing: TimeInterval = 600) -> RulerModel.PanelSnapshot {
            let watchLimits = WatchLimits(earliest: limits.earliest, latest: limits.latest, homeBy: limits.homeBy, packing: packing)
            let refreshed = RulerModel(batch: TrafficBatch(routeID: "office-home", checkedAt: date, samples: samples),
                                            limits: watchLimits, suggestedDeparture: suggested.suggestion.departure, calendar: calendar)!
            return snapshot(.watching, date, refreshed, committed: true)
        }
        let noFitLimits = WatchLimits(earliest: time(17, 35), latest: time(17, 40), homeBy: time(18, 0), packing: 600)
        let noFit = model(noFitLimits, [DepartureEstimate(departure: time(17, 35), driving: 1800),
                                       DepartureEstimate(departure: time(17, 40), driving: 1860)], checkedAt: time(17, 23))
        let expired = RulerModel(batch: TrafficBatch(routeID: "office-home", checkedAt: time(17, 2), samples: samples),
                                     limits: limits, suggestedDeparture: suggested.suggestion.departure, calendar: calendar)!
        return [
            ("no-journey", snapshot(.noRoute, now)),
            ("checking-5-of-7", RulerModel.PanelSnapshot(state: .checking, limits: limits, now: now, calendar: calendar,
                 model: suggested, routeTitle: "Office → Home", expectedCount: 7, receivedCount: 5, newestBarProgress: 0.5)),
            ("suggested", snapshot(.suggested, now, suggested)),
            ("watching-waiting", watching(now)),
            ("wrap-up-now", watching(time(17, 22))),
            ("leave-now", watching(time(17, 30))),
            ("paused", snapshot(.paused, time(17, 8), expired, committed: true)),
            ("stale", snapshot(.stale, time(17, 8), expired, committed: true)),
            ("missed", watching(time(17, 31))),
            ("no-departure-fits", snapshot(.noFit, time(17, 23), noFit)),
            ("no-wrap-up", watching(now, packing: 0))
        ]
    }
}
