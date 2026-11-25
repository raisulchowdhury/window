import Foundation
import MapKit
import UserNotifications

struct LiveWatchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor protocol TrafficProviding: AnyObject {
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate
}

/// Each request has its own timeout and completes exactly once, including cancellation.
@MainActor private final class ETAOperation {
    let directions: MKDirections
    let departure: Date
    var continuation: CheckedContinuation<DepartureEstimate, Error>?
    var timeout: Task<Void, Never>?
    var completed = false
    init(origin: SavedPlace, destination: SavedPlace, departure: Date) {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .automobile
        request.departureDate = departure
        self.departure = departure
        directions = MKDirections(request: request)
    }
    func run() async throws -> DepartureEstimate {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                    self?.finish(.failure(LiveWatchError(message: MapsErrorCopy.notResponding)))
                }
                directions.calculateETA { [weak self] response, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let response {
                            let estimate = DepartureEstimate(departure: self.departure, driving: response.expectedTravelTime)
                            guard estimate.valid, abs(response.expectedDepartureDate.timeIntervalSince(self.departure)) < 120 else {
                                self.finish(.failure(LiveWatchError(message: "Apple Maps did not return a usable estimate for this departure."))); return
                            }
                            self.finish(.success(estimate))
                        } else { self.finish(.failure(LiveWatchError(message: MapsErrorCopy.message(for: error, request: .route)))) }
                    }
                }
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }
    func finish(_ result: Result<DepartureEstimate, Error>) {
        guard !completed else { return }; completed = true
        timeout?.cancel(); timeout = nil
        let completion = continuation; continuation = nil
        completion?.resume(with: result)
        directions.cancel()
    }
}
@MainActor final class AppleTrafficProvider: TrafficProviding {
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        let operation = ETAOperation(origin: origin, destination: destination, departure: departing)
        return try await operation.run()
    }
}

/// A typed fragment's suggestion. Choosing one runs a full search; a result
/// must still be selected before it becomes a route endpoint.
struct PlaceSuggestion: Identifiable, Equatable {
    let title: String
    let subtitle: String
    var id: String { title + "\n" + subtitle }
    var query: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }
}

/// MapKit calls the completer's delegate on the main thread.
@MainActor final class PlaceCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    private let searchCompleter = MKLocalSearchCompleter()
    private let update: ([PlaceSuggestion]) -> Void
    init(update: @escaping ([PlaceSuggestion]) -> Void) {
        self.update = update
        super.init()
        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address, .pointOfInterest]
    }
    func query(_ fragment: String) { searchCompleter.queryFragment = fragment }
    func cancel() { searchCompleter.cancel() }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        update(completer.results.prefix(5).map { PlaceSuggestion(title: $0.title, subtitle: $0.subtitle) })
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { update([]) }
}

/// Typing asks Apple Maps for suggestions; a full search runs on Search, Return or a
/// chosen suggestion. A result must be selected before it becomes a route endpoint.
@MainActor final class PlaceSearch: ObservableObject {
    @Published var results: [SavedPlace] = []
    @Published var suggestions: [PlaceSuggestion] = []
    @Published var busy = false
    @Published var error: String?
    private var search: MKLocalSearch?
    private var revision = 0
    private var deadline: Task<Void, Never>?
    private var fragment: String?
    private lazy var completer = PlaceCompleter { [weak self] suggestions in
        guard let self, self.fragment != nil, !self.busy, self.results.isEmpty else { return }
        self.suggestions = suggestions
    }
    /// Empty text clears the suggestions and stops asking.
    func complete(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { fragment = nil; suggestions = []; completer.cancel(); return }
        fragment = trimmed
        completer.query(trimmed)
    }
    func find(_ query: String) {
        cancel(); results = []; error = nil
        fragment = nil; suggestions = []; completer.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = revision
        busy = true
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request); self.search = search
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, self.revision == token else { return }
            self.cancel(); self.error = MapsErrorCopy.notResponding
        }
        search.start { [weak self] response, error in
            Task { @MainActor in
                guard let self, self.revision == token else { return }
                self.deadline?.cancel(); self.deadline = nil; self.busy = false; self.search = nil
                guard let response else { self.error = MapsErrorCopy.message(for: error, request: .place); return }
                var seen = Set<String>()
                self.results = response.mapItems.compactMap { item in
                    let coordinate = item.location.coordinate
                    let place = SavedPlace(name: item.name ?? "Selected place", address: item.address?.fullAddress ?? item.name ?? "", latitude: coordinate.latitude, longitude: coordinate.longitude)
                    guard place.valid, seen.insert(place.id).inserted else { return nil }
                    return place
                }.prefix(6).map { $0 }
                if self.results.isEmpty { self.error = MapsErrorCopy.placeNotFound + " Include the city or street address." }
            }
        }
    }
    func cancel() { revision += 1; search?.cancel(); search = nil; deadline?.cancel(); deadline = nil; busy = false }
}

enum AlertAuthorization: String { case unknown, allowed, denied, unavailable }
@MainActor protocol WatchAlerting: AnyObject {
    func authorization(request: Bool) async -> AlertAuthorization
    func deliver(id: String, title: String, body: String) async throws
    func remove(ids: [String])
}
@MainActor final class LocalWatchAlerts: NSObject, WatchAlerting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?
    override init() { super.init(); center.delegate = self; center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications() }
    func authorization(request: Bool) async -> AlertAuthorization {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined && request {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { NSLog("Window notification authorization failed: %@", error.localizedDescription); return .unavailable }
            settings = await center.notificationSettings()
        }
        switch settings.authorizationStatus {
        case .authorized:
            let showsAlert = settings.alertSetting == .enabled && settings.alertStyle != .none
            return showsAlert || settings.soundSetting == .enabled ? .allowed : .denied
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
    /// Immediate only. Nothing is queued for a later time when the app might be asleep, offline, or closed.
    func deliver(id: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func remove(ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids); center.removeDeliveredNotifications(withIdentifiers: ids) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?(); completionHandler() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound, .list]) }
}
