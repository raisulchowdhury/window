// This test-only shim supplies observation names, NOT an AppKit/SwiftUI emulator.
// The production controller and policy run unchanged. Native lifecycle functions
// are excluded by WINDOW_PORTABLE_TESTS and require separate macOS verification.
#if WINDOW_PORTABLE_TESTS
import Foundation
protocol ObservableObject: AnyObject {}
@MainActor enum PortablePublications {
    static var willChange: (() -> Void)?
}
@MainActor @propertyWrapper final class Published<Value> {
    var wrappedValue: Value { willSet { PortablePublications.willChange?() } }
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum AlertAuthorization: String { case unknown, allowed, denied, unavailable }
@MainActor protocol TrafficProviding: AnyObject {
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate
}
@MainActor protocol WatchAlerting: AnyObject {
    func authorization(request: Bool) async -> AlertAuthorization
    func deliver(id: String, title: String, body: String) async throws
    func remove(ids: [String])
}
#endif
