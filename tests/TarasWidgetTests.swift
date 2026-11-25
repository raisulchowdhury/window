import Foundation

@main
@MainActor
struct TarasWidgetTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    static func main() throws {
        let now = PlanWidgetFixtures.all.first { $0.name == "wrap-up" }!.entry.date
        let calendar = PlanWidgetFixtures.calendar
        let departure = now.addingTimeInterval(180)
        let limits = WatchLimits(earliest: now, latest: departure.addingTimeInterval(600),
                                 homeBy: departure.addingTimeInterval(3600), packing: 120)
        let samples = [DepartureEstimate(departure: departure, driving: 1800)]
        func plan(_ state: PlanSnapshot.State = .watching, packing: Double = 120, expiry: Date? = nil, alerts: PlanSnapshot.AlertStatus = .allowed) throws -> PlanSnapshot {
            try PlanSnapshot(routeLabel: "Office → Home", limits: WatchLimits(earliest: limits.earliest, latest: limits.latest,
                    homeBy: limits.homeBy, packing: packing), samples: samples,
                    suggestedDeparture: departure, committedDeparture: state == .watching || state == .paused ? departure : nil,
                    checkedAt: now, expiresAt: expiry, state: state, alertStatus: alerts)
        }
        let snapshot = try plan()
        let entries = PlanWidgetTimeline.entries(snapshot: snapshot, now: now)
        expect(entries.map(\.date) == [now, departure.addingTimeInterval(60), now.addingTimeInterval(300)], "widget marks a missed or expired plan without scheduling live cues")
        for (offset, word, state) in [(0.0, "AS OF " + PlanWidgetModel(entry: entries[0], calendar: calendar).time(now), PlanWidgetModel.State.watching),
                                      (59.999, "AS OF 17:22", .watching), (60, "AS OF 17:22", .watching),
                                      (179.999, "AS OF 17:22", .watching), (180, "AS OF 17:22", .watching),
                                      (239.999, "AS OF 17:22", .watching), (240, "CHECK PLAN", .missed),
                                      (299.999, "CHECK PLAN", .missed), (300, "CHECK EXPIRED", .stale)] {
            let date = now.addingTimeInterval(offset)
            let presentation = PlanWidgetModel(entry: PlanWidgetEntry(date: date, snapshot: snapshot), calendar: calendar)
            expect(presentation.phaseWord == word, "phase at +\(offset)")
            expect(presentation.state == state, "state at +\(offset)")
        }
        expect(PlanWidgetTimeline.entries(snapshot: snapshot, now: departure).map(\.date) == [departure, departure.addingTimeInterval(60), snapshot.expiresAt], "never emits past entries")
        expect(PlanWidgetTimeline.entries(snapshot: snapshot, now: snapshot.expiresAt).count == 1, "expired snapshot is terminal")
        let earlyExpiry = try plan(expiry: now.addingTimeInterval(30))
        expect(PlanWidgetTimeline.entries(snapshot: earlyExpiry, now: now).map(\.date) == [now, earlyExpiry.expiresAt], "expiry before all cues")
        let tiedExpiry = try plan(expiry: departure)
        let tied = PlanWidgetTimeline.entries(snapshot: tiedExpiry, now: now)
        expect(tied.map(\.date) == [now, departure], "expiry at the departure remains terminal")
        expect(PlanWidgetModel(entry: tied.last!, calendar: calendar).state == .stale, "expiry wins simultaneous departure")
        let zero = try plan(packing: 0)
        expect(PlanWidgetTimeline.entries(snapshot: zero, now: now).map(\.date) == [now, departure.addingTimeInterval(60), zero.expiresAt], "zero packing keeps the same passive timeline")
        expect(PlanWidgetModel(entry: PlanWidgetEntry(date: departure.addingTimeInterval(-1), snapshot: zero)).phaseWord != "WRAP UP NOW", "zero packing never cues preparation")
        for state in [PlanSnapshot.State.suggested, .paused] {
            let p = try plan(state)
            for offset in [0.0, 60, 180, 240] {
                let model = PlanWidgetModel(entry: PlanWidgetEntry(date: now.addingTimeInterval(offset), snapshot: p))
                expect(model.phaseWord == (state == .suggested ? "NOT WATCHING" : "OPEN WINDOW"), "uncommitted/paused never cues at \(offset)")
                expect(model.dim, "uncommitted/paused time dim")
            }
        }
        for status in [PlanSnapshot.AlertStatus.unknown, .denied, .unavailable, .failed] {
            let noAlerts = try plan(alerts: status)
            let model = PlanWidgetModel(entry: PlanWidgetEntry(date: departure, snapshot: noAlerts))
            expect(model.mediumHeaderRight == "ALERTS OFF", "medium widget shows that alerts are off")
            expect(model.phaseWord == "ALERTS OFF", "small widget shows that alerts are off")
            expect(model.departure != "—", "departure time remains visible without alerts")
            let missed = PlanWidgetModel(entry: PlanWidgetEntry(date: departure.addingTimeInterval(60), snapshot: noAlerts))
            expect(missed.smallFooter == "OPEN WINDOW TO RECHECK", "missed departure supersedes alert status")
        }
        let rolledBack = PlanWidgetTimeline.entries(snapshot: snapshot, now: now.addingTimeInterval(-120))
        expect(rolledBack.count == 1, "clock rollback makes stale timeline terminal")
        expect(PlanWidgetModel(entry: rolledBack[0]).state == .stale, "future-checked snapshot cannot cue after rollback")
        expect(PlanWidgetTimeline.entries(snapshot: nil, now: now).count == 1, "missing snapshot has one entry")
        expect(PlanWidgetModel(entry: PlanWidgetEntry(date: now, snapshot: nil)).state == .noPlan, "missing snapshot no plan")
        let idle = try PlanWidgetFixtures.make(state: "no-plan", now: now)
        expect(PlanWidgetTimeline.entries(snapshot: idle, now: now).count == 1, "idle has no cues or expiry")
        expect(PlanWidgetModel(entry: PlanWidgetEntry(date: now, snapshot: idle)).headerLeft == "NO PLAN", "idle shows no plan")
        let suiteName = "window-widget-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("WP0 hello", forKey: PlanSnapshotStore.key)
        expect(PlanSnapshotStore.read(from: defaults) == nil, "legacy string safely becomes no plan")
        let firstChanged = try PlanSnapshotStore.write(snapshot, to: defaults)
        expect(firstChanged, "first write changed")
        expect(PlanSnapshotStore.read(from: defaults) == snapshot, "app-group round trip")
        let identicalChanged = try PlanSnapshotStore.write(snapshot, to: defaults)
        expect(!identicalChanged, "identical write unchanged; no reload")
        let idleChanged = try PlanSnapshotStore.write(idle, to: defaults)
        expect(idleChanged, "clearing plan changed")
        let data = try JSONEncoder().encode(snapshot)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for version in [0, 2] {
            object["version"] = version
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: PlanSnapshotStore.key)
            expect(PlanSnapshotStore.read(from: defaults) == nil, "reject version \(version)")
        }
        object["version"] = 1
        object["samples"] = Array(repeating: (object["samples"] as! [Any])[0], count: 13)
        expect((try? JSONDecoder().decode(PlanSnapshot.self, from: JSONSerialization.data(withJSONObject: object))) == nil, "reject >12 samples from persisted data")
        defaults.set(Data("{broken".utf8), forKey: PlanSnapshotStore.key)
        expect(PlanSnapshotStore.read(from: defaults) == nil, "corrupt snapshot safely becomes no plan")
        for fixture in PlanWidgetFixtures.all {
            let model = PlanWidgetModel(entry: fixture.entry, calendar: calendar)
            expect(model.state == .noPlan || model.rows.count == 4, "fixture \(fixture.name) has complete rows")
            let roundTrip = try JSONDecoder().decode(PlanSnapshot.self, from: JSONEncoder().encode(fixture.entry.snapshot!))
            expect(roundTrip == fixture.entry.snapshot, "fixture \(fixture.name) round trips")
            if let rulerModel = model.panel?.model, let sample = model.selectedSample {
                for small in [true, false] {
                    let width = small ? 142.0 : 336.0, height = small ? 30.0 : 34.0
                    let ruler = rulerModel.miniRuler(width: width, height: height, small: small, center: sample.departure, dim: model.dim)
                    expect(ruler.ticks.count == (small ? 57 : 69), "one tick per minute \(fixture.name)")
                    expect(zip(ruler.ticks, ruler.ticks.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 60 }, "minute spacing \(fixture.name)")
                    expect(ruler.bars.count == fixture.entry.snapshot!.samples.count, "one bar per actual sample")
                    expect(ruler.bars.allSatisfy { $0.height.isFinite && $0.height >= height * 0.32 && $0.height <= height * 0.87 + 0.001 }, "bounded sample heights")
                    expect(abs(ruler.cursorX - width * (small ? 38 / 56.0 : 44 / 68.0)) < 0.001, "reference cursor position")
                }
            }
        }
        let long = PlanWidgetFixtures.all.first { $0.name == "long-route-countdown" }!
        let longModel = PlanWidgetModel(entry: long.entry, calendar: calendar)
        expect(longModel.snapshot?.routeLabel == "North Campus → Harbor Terminal", "capture fixture uses a long route")
        expect(longModel.phaseWord == "AS OF 17:22", "widget labels the age of the forecast")
        expect(longModel.smallHeader == "LEAVE AT", "small widget drops route before numbers")
        expect(longModel.smallFooter == "54M · ARRIVAL \(longModel.arrival)", "small footer keeps complete drive and home time")
        expect(longModel.leaveLabel == "LEAVE AT" && longModel.wrapLabel == "WRAP UP", "medium labels have no cached countdown")
        let equalModel = TarasRulerModel(batch: TrafficBatch(routeID: "equal", checkedAt: now, samples: samples), limits: limits, suggestedDeparture: departure)!
        expect(equalModel.miniRuler(width: 142, height: 30, small: true, center: departure, dim: false).bars.allSatisfy { $0.height == 9.6 }, "equal drives avoid division by zero")
        print("PASS: \(checks) widget checks")
    }
}
