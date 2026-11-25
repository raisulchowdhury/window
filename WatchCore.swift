import Foundation

/// A user-confirmed place. Stored locally; coordinates are sent only to Apple Maps for this journey.
struct SavedPlace: Codable, Equatable, Identifiable {
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(latitude),\(longitude)" }
    var valid: Bool { !name.isEmpty && latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}
struct SavedJourney: Codable, Equatable {
    var origin: SavedPlace?
    var destination: SavedPlace?
    var earliest = 1030
    var latest = 1060
    var homeBy = 1095
    var packing = 5
    var appearance = "System"
    var routeID: String? {
        guard let origin, let destination, origin.valid, destination.valid else { return nil }
        return origin.id + "→" + destination.id
    }
    var valid: Bool { (0..<1440).contains(earliest) && (0..<1440).contains(latest) && (0..<1440).contains(homeBy) && (0...30).contains(packing) && ["System", "Light", "Dark"].contains(appearance) }
    func limits(on date: Date, calendar: Calendar = .current) -> WatchLimits? {
        func at(_ minute: Int) -> Date? {
            guard let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                           of: date, matchingPolicy: .strict), calendar.isDate(time, inSameDayAs: date) else { return nil }
            return time
        }
        guard valid, let start = at(earliest), let end = at(latest), let arrival = at(homeBy) else { return nil }
        return WatchLimits(earliest: start, latest: end, homeBy: arrival, packing: Double(packing * 60))
    }
}
public struct WatchLimits: Equatable, Codable {
    public let earliest: Date
    public let latest: Date
    public let homeBy: Date
    public let packing: TimeInterval
    public var buffer: TimeInterval = 600
    /// The spare Window plans into every arrival unless a recovery changes it.
    public static let defaultBuffer: TimeInterval = 600
    public init(earliest: Date, latest: Date, homeBy: Date, packing: TimeInterval, buffer: TimeInterval = WatchLimits.defaultBuffer) {
        self.earliest = earliest; self.latest = latest; self.homeBy = homeBy
        self.packing = packing; self.buffer = buffer
    }
    public func validation(at now: Date) -> String? {
        if earliest > latest { return "“Latest leave” must come after “Earliest leave”." }
        if latest >= homeBy { return "“Arrive by” must come after “Latest leave”." }
        if latest.timeIntervalSince(earliest) > 3 * 3600 { return "Keep the departure window within three hours." }
        if now.addingTimeInterval(packing) > latest { return "Today’s departure window has passed. Update your times." }
        return nil
    }
    public func fits(_ estimate: DepartureEstimate) -> Bool {
        estimate.departure >= earliest && estimate.departure <= latest && estimate.arrival.addingTimeInterval(buffer) <= homeBy
    }
}
public struct DepartureEstimate: Equatable, Codable {
    public let departure: Date
    public let driving: TimeInterval
    public init(departure: Date, driving: TimeInterval) {
        self.departure = departure; self.driving = driving
    }
    public var arrival: Date { departure.addingTimeInterval(driving) }
    public var displayDrivingMinutes: Int { max(1, Int((driving / 60).rounded())) }
    public var displayArrival: Date {
        Date(timeIntervalSinceReferenceDate: (arrival.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }
    public var valid: Bool { driving.isFinite && driving > 0 && driving < 24 * 3600 }
}
public struct TrafficBatch {
    public let routeID: String
    public let checkedAt: Date
    public let samples: [DepartureEstimate]
    public init(routeID: String, checkedAt: Date, samples: [DepartureEstimate]) {
        self.routeID = routeID; self.checkedAt = checkedAt; self.samples = samples
    }
    public var expiresAt: Date { checkedAt.addingTimeInterval(5 * 60) }
    public func isFresh(at now: Date) -> Bool { now >= checkedAt.addingTimeInterval(-1) && now < expiresAt }
    public func sample(at date: Date) -> DepartureEstimate? { samples.first { abs($0.departure.timeIntervalSince(date)) < 0.5 } }
}
/// Temporal phase only. Freshness, connectivity and permission remain separate gates.
/// The one-minute missed threshold matches the existing live-watch contract.
enum DepartureCuePhase: Equatable {
    case waiting, wrappingUp, leaveNow, missed

    static func resolve(now: Date, departure: Date, packing: TimeInterval,
                        preparationAlreadyUnderway: Bool = false) -> DepartureCuePhase {
        if now >= departure.addingTimeInterval(60) { return .missed }
        if now >= departure { return .leaveNow }
        if preparationAlreadyUnderway || now >= departure.addingTimeInterval(-max(0, packing)) {
            return .wrappingUp
        }
        return .waiting
    }
}

enum DeparturePolicy {
    static func roundedMinute(_ date: Date) -> Date { Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / 60) * 60) }
    static func readiness(now: Date, limits: WatchLimits, preparedFor: Date? = nil) -> Date {
        max(limits.earliest, roundedMinute(max(now, preparedFor ?? now.addingTimeInterval(limits.packing))))
    }
    /// Up to nine evenly spaced samples, plus the current commitment and an explicitly requested alternative.
    /// Only returned samples may become recommendations; there is no interpolation or synthetic ETA fallback.
    static func candidates(now: Date, limits: WatchLimits, committed: Date?, requested: Date? = nil, preparedFor: Date? = nil) -> [Date] {
        let first = readiness(now: now, limits: limits, preparedFor: preparedFor)
        var dates = Set<Date>()
        if first <= limits.latest {
            let span = limits.latest.timeIntervalSince(first)
            let step = max(5 * 60, ceil(span / 8 / 60) * 60)
            var date = first
            while date <= limits.latest { dates.insert(date); date = date.addingTimeInterval(step) }
            dates.insert(limits.latest)
            let nextMinute = first.addingTimeInterval(60)
            if committed == nil, requested == nil, preparedFor == nil,
               first.timeIntervalSince(now.addingTimeInterval(limits.packing)) <= 60, nextMinute <= limits.latest {
                // Keep a near-term option when checking crosses the readiness minute.
                dates.insert(nextMinute)
            }
        }
        for date in [committed, requested].compactMap({ $0 }) where date >= now && date <= limits.latest && date >= limits.earliest { dates.insert(date) }
        return dates.sorted()
    }
    static func recommend(_ samples: [DepartureEstimate], limits: WatchLimits, now: Date, committed: Date?, preparedFor: Date? = nil) -> DepartureEstimate? {
        let feasible = samples.filter { $0.valid && $0.departure >= now && limits.fits($0) }.sorted { $0.departure < $1.departure }
        // Once the cue has fired, a clock tick cannot pretend that packing has to start again.
        if let committed, let retained = feasible.first(where: { abs($0.departure.timeIntervalSince(committed)) < 0.5 }) { return retained }
        let ready = readiness(now: now, limits: limits, preparedFor: preparedFor)
        let choices = feasible.filter { $0.departure >= ready }
        return meaningfulDriving(choices)
    }
    static func earliestArrival(_ choices: [DepartureEstimate]) -> DepartureEstimate? {
        choices.min { $0.arrival == $1.arrival ? $0.departure < $1.departure : $0.arrival < $1.arrival }
    }
    static func lessDrivingAlternative(_ choices: [DepartureEstimate], comparedWith primary: DepartureEstimate) -> DepartureEstimate? {
        choices.filter { $0.departure > primary.departure && primary.driving - $0.driving >= 8 * 60 }
            .min { $0.driving == $1.driving ? $0.arrival < $1.arrival : $0.driving < $1.driving }
    }
}
/// All three parts use the same pair of estimates; less driving is not total time saved.
struct DepartureTradeoff {
    let waitMinutes: Int
    let drivingMinutesSaved: Int
    var arrivalMinutesLater: Int { waitMinutes - drivingMinutesSaved }
    init(_ choice: DepartureEstimate, comparedWith baseline: DepartureEstimate) {
        waitMinutes = Int((choice.departure.timeIntervalSince(baseline.departure) / 60).rounded())
        drivingMinutesSaved = Int(((baseline.driving - choice.driving) / 60).rounded())
    }
    var text: String {
        let wait = waitMinutes > 0 ? "Wait \(waitMinutes) min" : waitMinutes < 0 ? "Leave \(-waitMinutes) min sooner" : "No extra wait"
        let drive = drivingMinutesSaved > 0 ? "drive \(drivingMinutesSaved) min less" : drivingMinutesSaved < 0 ? "drive \(-drivingMinutesSaved) min more" : "same driving time"
        let arrival = arrivalMinutesLater > 0 ? "arrive \(arrivalMinutesLater) min later" : arrivalMinutesLater < 0 ? "arrive \(-arrivalMinutesLater) min earlier" : "arrive at the same time"
        return "\(wait) · \(drive) · \(arrival)"
    }
}

/// Recovery is an explicit exception for this watch, using actual checked estimates only.
struct RecoveryOptions {
    let primary: DepartureEstimate
    let alternative: DepartureEstimate?
}
enum RecoveryPolicy {
    static func options(_ samples: [DepartureEstimate], limits: WatchLimits, now: Date, preparedFor: Date? = nil) -> RecoveryOptions? {
        let ready = DeparturePolicy.readiness(now: now, limits: limits, preparedFor: preparedFor)
        let choices = samples.filter { $0.valid && $0.departure >= ready && Calendar.current.isDate($0.departure, inSameDayAs: now) }
        guard let primary = DeparturePolicy.earliestArrival(choices) else { return nil }
        let alternative = DeparturePolicy.lessDrivingAlternative(choices, comparedWith: primary)
        return RecoveryOptions(primary: primary, alternative: alternative)
    }
    static func acceptedLimits(for choice: DepartureEstimate, original: WatchLimits) -> WatchLimits {
        let stillOnTime = choice.arrival <= original.homeBy
        let buffer = stillOnTime ? min(original.buffer, floor(original.homeBy.timeIntervalSince(choice.arrival) / 60) * 60) : original.buffer
        return WatchLimits(earliest: original.earliest, latest: max(original.latest, choice.departure),
                           homeBy: stillOnTime ? original.homeBy : DeparturePolicy.roundedMinute(choice.arrival.addingTimeInterval(buffer)),
                           packing: original.packing, buffer: buffer)
    }
}

/// Reject completions from a previous route, refresh, or ended watch, even if a provider ignores cancellation.
struct WatchRequestGate {
    private(set) var revision = 0
    private(set) var session: UUID?
    mutating func begin() { session = UUID(); revision += 1 }
    mutating func next() -> Int { revision += 1; return revision }
    mutating func stop() { session = nil; revision += 1 }
    func accepts(_ revision: Int, session: UUID) -> Bool { self.revision == revision && self.session == session }
}

struct JourneyStore {
    let defaults: UserDefaults
    private let key = "window.live.savedJourney.v1"
    func load() -> SavedJourney {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(SavedJourney.self, from: data), settings.valid,
              settings.origin?.valid != false, settings.destination?.valid != false else { return SavedJourney() }
        return settings
    }
    func save(_ settings: SavedJourney) { if settings.valid, let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) } }
}

/// Plain words for Apple Maps failures, so raw MapKit text never reaches the person.
enum MapsErrorCopy {
    static let placeNotFound = "Couldn’t find that place."
    static let noRoute = "No route found."
    static let notResponding = "Apple Maps isn’t responding. Try again."
    enum Request { case place, route }
    /// MKErrorDomain codes: 1 unknown, 2 server failure, 3 throttled,
    /// 4 placemark not found, 5 directions not found, 6 decoding failed.
    /// Network failures, timeouts and anything unrecognised read as not responding.
    static func message(for error: Error?, request: Request) -> String {
        guard let error else { return request == .place ? placeNotFound : noRoute }
        let nsError = error as NSError
        if nsError.domain == "MKErrorDomain" {
            switch nsError.code {
            case 4: return request == .place ? placeNotFound : noRoute
            case 5: return noRoute
            default: return notResponding
            }
        }
        return notResponding
    }
}
