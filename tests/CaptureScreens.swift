import AppKit
import SwiftUI

/// Renders the deeper windows (journey editor and its sheets, recovery review,
/// details, settings) in the shipped native build with an isolated fixture watch.
/// Offscreen bitmaps can omit glass; inspect them, a count is not a pass.
@main struct CaptureScreens {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var captures = 0
        for scale: CGFloat in [1, 1.4] {
            // Settings reads its size from its own stored preference. This
            // executable's defaults domain is its own, not the app's.
            UserDefaults.standard.set(Double(scale), forKey: "window.textScale")
            let fixture = LiveFixture()
            defer { fixture.clean() }
            // The panel fixture's evening (PanelFixtures): ten minutes of wrap-up, so
            // details, editor and panel show the same 17:30 leave and 17:20 wrap-up.
            fixture.watch.settings.packing = 10
            fixture.watch.makeUsualTimes()
            await fixture.start()
            // Short names as the panel shows them (OFFICE → HOME), addresses underneath.
            fixture.watch.settings.origin = SavedPlace(name: "Office", address: "100 Innovation Way", latitude: 37, longitude: -122)
            let w = fixture.watch!
            let editor = WindowTextMetrics.editorWidth(300, scale: scale)
            // A departure that arrives ten minutes after the limit, reviewed in the recovery window.
            let limits = w.limits ?? WatchLimits(earliest: w.now, latest: w.now.addingTimeInterval(1800),
                                                 homeBy: w.now.addingTimeInterval(4500), packing: 600)
            let late = DepartureEstimate(departure: limits.latest, driving: limits.homeBy.timeIntervalSince(limits.latest) + 600)
            // The sheets open on the journey's own values, as the editor passes them.
            let journey = w.settings
            func current(_ field: TimeField) -> Int {
                switch field {
                case .earliest: return journey.earliest
                case .latest: return journey.latest
                case .homeBy: return journey.homeBy
                }
            }
            var views: [(String, AnyView, NSSize)] = [
                ("journey", AnyView(JourneyEditor(watch: w, openRoute: false, close: {})),
                 NSSize(width: WindowTextMetrics.editorWidth(420, scale: scale), height: 425 + (scale - 1) * 150 + 40)),
                ("wrap-up", AnyView(WrapUpValueEditor(minutes: .constant(journey.packing))), NSSize(width: editor, height: 280 + 200 * (scale - 1))),
                ("route", AnyView(LiveRouteEditor(journey: .constant(w.settings))),
                 NSSize(width: WindowTextMetrics.editorWidth(380, scale: scale), height: 430 + 300 * (scale - 1))),
                ("details", AnyView(WatchDetailsView(onDone: {}, watch: w)),
                 NSSize(width: WindowTextMetrics.editorWidth(340, scale: scale), height: 490)),
                ("recovery", AnyView(RecoveryView(rows: RulerModel.recoveryRows(for: late, original: limits),
                                                        details: w.recoveryConsent(late), cancel: {}, accept: {})),
                 NSSize(width: WindowTextMetrics.editorWidth(380, scale: scale), height: 480 + (scale - 1) * 300)),
                ("settings", AnyView(LiveSettingsView(watch: w)),
                 NSSize(width: WindowTextMetrics.editorWidth(440, scale: scale), height: 400 + (scale - 1) * 400)),
            ]
            for field in TimeField.allCases {
                views.append(("time-" + field.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"),
                              AnyView(TimeValueEditor(field: field, minutes: .constant(current(field)), day: w.now)),
                              NSSize(width: editor, height: 240 + 200 * (scale - 1))))
            }
            // Details with notification permission undecided and denied: the controls and reasons
            // the allowed-state capture above never shows.
            var extra: [LiveFixture] = []
            defer { extra.forEach { $0.clean() } }
            for (state, label) in [(AlertAuthorization.unknown, "undecided"), (.denied, "denied")] {
                let other = LiveFixture()
                extra.append(other)
                other.alerts.state = state
                other.watch.settings.packing = 10
                other.watch.makeUsualTimes()
                await other.start()
                other.watch.updateAuthorization(request: false)
                await settle { !other.watch.requestingAlertPermission }
                views.append(("details-\(label)", AnyView(WatchDetailsView(onDone: {}, watch: other.watch)),
                              NSSize(width: WindowTextMetrics.editorWidth(340, scale: scale), height: 490)))
            }
            for (name, view, size) in views {
                let root = view
                    .windowReadingSurface(appearance: "Dark")
                    .environment(\.windowTextScale, scale)
                // Hosted and sized as LiveController.show does: by the content's fitting size,
                // so a capture shows exactly what the window would, clipping included.
                let controller = NSHostingController(rootView: root)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentViewController = controller
                let host = controller.view
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let fit = host.fittingSize
                let fitted = fit.width >= 100 && fit.height >= 100 ? fit : size
                window.setContentSize(fitted)
                host.frame = NSRect(origin: .zero, size: fitted)
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap for \(name)") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let tag = "\(name)-\(Int((scale * 100).rounded()))"
                guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("No PNG for \(tag)") }
                try! data.write(to: output.appendingPathComponent(tag + ".png"))
                print("\(tag): \(Int(fitted.width))x\(Int(fitted.height)) pt (fitting \(Int(fit.width))x\(Int(fit.height)))")
                window.contentViewController = nil
                captures += 1
            }
        }
        UserDefaults.standard.removeObject(forKey: "window.textScale")
        print("Rendered \(captures) deeper-screen captures (native build, dark). Glass may be missing offscreen.")
    }
}
