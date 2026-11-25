import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

@MainActor private final class MonitoringTraffic: TrafficProviding {
    let fastAfter: Date
    init(fastAfter: Date) { self.fastAfter = fastAfter }
    func estimate(from origin: SavedPlace, to destination: SavedPlace, departing: Date) async throws -> DepartureEstimate {
        DepartureEstimate(departure: departing, driving: departing < fastAfter ? 55 * 60 : 30 * 60)
    }
}

@MainActor private final class MonitoringAlerts: WatchAlerting {
    func authorization(request: Bool) async -> AlertAuthorization { .denied }
    func deliver(id: String, title: String, body: String) async throws {}
    func remove(ids: [String]) {}
}

@MainActor private final class MonitoringFixture {
    let day = Calendar.current.startOfDay(for: Date())
    let suite = "window-monitoring-copy-\(UUID().uuidString)"
    var date: Date
    var watch: LiveWatch!
    init() {
        date = Calendar.current.date(bySettingHour: 17, minute: 5, second: 0, of: day)!
        let defaults = UserDefaults(suiteName: suite)!
        var journey = SavedJourney()
        journey.origin = SavedPlace(name: "Office", address: "Fictional office", latitude: 37, longitude: -122)
        journey.destination = SavedPlace(name: "Home", address: "Fictional home", latitude: 38, longitude: -122)
        let store = JourneyStore(defaults: defaults); store.save(journey)
        let departure = Calendar.current.date(bySettingHour: 17, minute: 30, second: 0, of: day)!
        watch = LiveWatch(store: store, provider: MonitoringTraffic(fastAfter: departure), alerts: MonitoringAlerts(),
                          clock: { [weak self] in self?.date ?? .distantPast })
    }
    func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: day)!
    }
    func advance(_ hour: Int, _ minute: Int, _ second: Int = 0) {
        date = at(hour, minute, second); watch.tick()
    }
    func clean() { watch.shutdown(); UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
}

#if !WINDOW_CORE_TESTS
@main
#endif
struct MonitoringCopyTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    @MainActor private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("FAIL: monitoring-copy test did not settle")
    }
    @MainActor private static func start(_ f: MonitoringFixture) async {
        f.watch.begin(); await settle { !f.watch.checking }
        guard let offer = f.watch.proposal else { fatalError("FAIL: missing fictional departure") }
        expect(f.watch.acceptOffer(offer), "accept the checked fixture departure")
        expect(f.watch.plan?.departure == f.at(17, 30), "known 17:30 departure")
    }
    @MainActor static func main() async {
        let due = MonitoringFixture(); defer { due.clean() }
        await start(due)
        due.advance(17, 29); await settle { !due.watch.checking }
        expect(due.watch.nextCheck != nil, "future departure permits automatic checks")
        due.advance(17, 30); await settle { !due.watch.checking }
        expect(!due.watch.needsNewDeparture, "exact departure boundary is not past")
        due.advance(17, 30, 1)
        expect(due.watch.needsNewDeparture && !due.watch.missed, "one second past is within the due-minute grace period")
        expect(due.watch.nextCheck == nil, "no automatic-check promise after refresh stops, even inside due-minute grace")

        let offline = MonitoringFixture(); defer { offline.clean() }
        await start(offline)
        offline.watch.connectivityChanged(false)
        expect(offline.watch.staleExplanation.contains("Checks resume"), "future offline departure can resume checks")
        offline.advance(17, 31)
        expect(offline.watch.stale && offline.watch.needsNewDeparture, "offline missed fixture is unconfirmed")
        expect(offline.watch.staleExplanation.contains("Recheck from now"), "offline passed departure names the manual action")
        expect(!offline.watch.staleExplanation.contains("Checks resume"), "offline missed departure does not promise automatic recovery")
        expect(offline.watch.pauseReason?.contains("Recheck from now") == true, "spoken pause reason also explains the manual recovery condition")
        offline.watch.refresh() // The online guard can also supply the spoken pause reason.
        expect(offline.watch.pauseReason?.contains("Recheck from now") == true, "blocked refresh cannot restore an automatic-recovery promise")
        offline.watch.connectivityChanged(true)
        expect(offline.watch.staleExplanation.contains("Recheck from now"), "reconnection does not repeat an obsolete automatic-resume promise")
        expect(offline.watch.nextCheck == nil, "reconnection cannot advertise an automatic check for a past departure")
        offline.watch.refresh(replan: true); await settle { !offline.watch.checking }
        expect(!offline.watch.stale, "explicit recheck recovers using fresh evidence")

        let sleeping = MonitoringFixture(); defer { sleeping.clean() }
        await start(sleeping)
        sleeping.watch.setSleeping(true)
        expect(sleeping.watch.staleExplanation.contains("Checks resume"), "future sleeping departure can resume checks")
        sleeping.advance(17, 31)
        expect(sleeping.watch.staleExplanation.contains("Recheck from now"), "asleep past departure names the manual action")
        expect(!sleeping.watch.staleExplanation.contains("Checks resume"), "sleeping missed departure does not promise automatic recovery")
        expect(sleeping.watch.pauseReason?.contains("Recheck from now") == true, "spoken sleep message preserves recovery limits")
        sleeping.watch.setSleeping(false)
        expect(sleeping.watch.staleExplanation.contains("Recheck from now"), "waking after departure still requires a manual check")
        expect(sleeping.watch.nextCheck == nil, "wake does not advertise a check that the controller will skip")

        print("PASS: \(checks) monitoring-copy regression checks; fake services, no native UI or alert presentation")
    }
}
