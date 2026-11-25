import Foundation
import WidgetKit
import WindowCore

enum WidgetSnapshot {
    static let appGroup: String? = {
        guard let appGroup = Bundle.main.object(forInfoDictionaryKey: "WindowAppGroup") as? String,
              !appGroup.isEmpty, !appGroup.contains("$("),
              // A build without a team expands the group to ".window.shared", which no container backs.
              !appGroup.hasPrefix(".") else {
            return nil
        }
        return appGroup
    }()
    static let key = PlanSnapshotStore.key
    static let kind = "WindowWidget"

    static func read() -> PlanSnapshot? {
        guard let appGroup, let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        return PlanSnapshotStore.read(from: defaults)
    }

    /// WP6 calls this after a plan change, including clearing today's plan with an idle snapshot.
    @discardableResult
    static func write(_ snapshot: PlanSnapshot, now: Date = Date()) throws -> Bool {
        guard let appGroup, let defaults = UserDefaults(suiteName: appGroup) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let changed = try TarasSnapshotWriter.write(snapshot, now: now, to: defaults)
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        return changed
    }

    #if DEBUG
    static func writeFixtureIfRequested(arguments: [String] = CommandLine.arguments) throws {
        guard let index = arguments.firstIndex(of: "--write-fixture-snapshot") else { return }
        guard arguments.indices.contains(index + 1) else {
            throw NSError(domain: "WindowFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "--write-fixture-snapshot requires a state"])
        }
        try write(PlanWidgetFixtures.make(state: arguments[index + 1]))
    }
    #endif
}
