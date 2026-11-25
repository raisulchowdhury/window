import AppKit
import SwiftUI
import WindowCore

@main
@MainActor
struct CaptureTarasMotion {
    typealias Snapshot = TarasRulerModel.PanelSnapshot
    enum MotionPath { case data, drag, park, home, open, close, hover, press, focus }
    struct Transition {
        let name: String
        let from: Snapshot
        let to: Snapshot
        let cause: PanelChange
        var duration = TarasMotion.maxTravel
        var path = MotionPath.data
        var startIndex: Int?
        var endIndex: Int?
        var preview = false
        var control: String?
    }
    static var records: [[String: Any]] = []

    static func main() async throws {
        try await TarasAnimatedTextTests.run()
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases = transitions()
        precondition(Set(cases.map(\.name)).count == cases.count)
        for reduced in [false, true] {
            let directory = reduced ? out.appendingPathComponent("reduce-motion", isDirectory: true) : out
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for transition in cases {
                var times = [0.0, transition.duration / 2, transition.duration]
                if transition.cause == .batchSettled {
                    times += [TarasMotion.settleDelay, TarasMotion.settleDelay + TarasMotion.textOut,
                              TarasMotion.settleDelay + TarasMotion.textOut + TarasMotion.textIn / 2]
                }
                for fraction in times.sorted().map({ $0 / transition.duration }) {
                    try panel(transition, fraction: fraction, reduced: reduced, directory: directory)
                }
            }
            try statusItems(directory: directory, reduced: reduced)
            try widgets(directory: directory, reduced: reduced)
        }
        let manifest: [String: Any] = [
            "format": "Window WP7 fixed-time fixture captures, 2 pixels per point",
            "clock": "Pure TarasRulerScene sampled from t = 0; no network, no WindowApp launch",
            "limits": [
                "Ruler and traffic bars use the production spring, easing and retargeting code.",
                "Panel alpha is a deterministic fade reference, not an AppKit window screenshot.",
                "Text, footer, tint and glyph frames are deterministic reference composites at the named timings. Native SwiftUI numericText glyphs, easing and spring presentation still need a live check.",
                "Status items and WidgetKit entries are static endpoint evidence, not system-compositor captures. Widget endpoints are identical between motion settings; the read-only system Reduce Motion environment must be exercised live.",
                "VoiceOver, hardware haptics, focus traversal, pointer interruption and frame pacing need live checks."
            ],
            "count": records.count,
            "frames": records
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("manifest.json"), options: .atomic)
        print("PASS: \(records.count) fixed-time frames; \(cases.count) panel transitions in normal and Reduce Motion. \(out.path)/manifest.json")
    }

    static func snapshot(_ base: Snapshot, state: TarasRulerModel.State? = nil,
                         model: TarasRulerModel? = nil, committed: Date? = nil,
                         checking: Bool = false, retained: Bool = false, received: Int = 0,
                         feedback: String? = nil, pause: String? = nil) -> Snapshot {
        let m = model ?? base.model
        return Snapshot(state: state ?? base.state, limits: base.limits, now: base.now, calendar: base.calendar,
                        model: m, routeTitle: base.routeTitle, committedDeparture: committed ?? base.committedDeparture,
                        expectedCount: checking ? (m?.samples.count ?? 7) : 0, receivedCount: received,
                        isChecking: checking, checkingKeepsEvidence: retained,
                        checkingSamples: checking ? Array((m?.samples ?? []).prefix(received)) : [],
                        readyForToday: true, delayAvailable: checking ? false : nil,
                        pauseLabel: pause, feedbackLabel: feedback)
    }

    static func transitions() -> [Transition] {
        let fixtures = Dictionary(uniqueKeysWithValues: TarasPanelFixtures.all.map { ($0.name, $0.snapshot) })
        let suggested = fixtures["suggested"]!, watch = fixtures["watching-waiting"]!
        let wrap = fixtures["wrap-up-now"]!, leave = fixtures["leave-now"]!, missed = fixtures["missed"]!
        let paused = fixtures["paused"]!, stale = fixtures["stale"]!, noFit = fixtures["no-departure-fits"]!
        let model = suggested.model!
        let ready = Snapshot(state: .noRoute, limits: suggested.limits, now: suggested.now, calendar: suggested.calendar,
                             routeTitle: suggested.routeTitle, readyForToday: true)
        let check0 = snapshot(suggested, state: .checking, checking: true)
        let check2 = snapshot(suggested, state: .checking, checking: true, received: 2)
        let check6 = snapshot(suggested, state: .checking, checking: true, received: 6)
        let check7 = snapshot(suggested, state: .checking, checking: true, received: 7)
        let recheck0 = snapshot(paused, state: .checking, checking: true, retained: true)
        let recheck2 = snapshot(paused, state: .checking, checking: true, retained: true, received: 2)
        let recheck7 = snapshot(paused, state: .checking, checking: true, retained: true, received: 7)
        let checkedAgain = snapshot(suggested, state: .watching, committed: model.suggestion.departure)
        let plusDeparture = model.samples[5].departure
        let plusChecking = snapshot(watch, checking: true, feedback: "CHECKING 17:35")
        let delayed = snapshot(watch, committed: plusDeparture)
        let rejected = snapshot(watch, feedback: "+5M DOESN'T FIT")
        let changedSamples = model.samples.enumerated().map { index, sample in
            DepartureEstimate(departure: sample.departure, driving: Double([41, 40, 38, 36, 35, 26, 25][index]) * 60)
        }
        let changedModel = TarasRulerModel(batch: TrafficBatch(routeID: model.batch.routeID,
            checkedAt: model.batch.checkedAt.addingTimeInterval(180), samples: changedSamples), limits: model.limits,
            suggestedDeparture: plusDeparture, calendar: model.calendar)!
        let changed = snapshot(suggested, model: changedModel, feedback: "TRAFFIC CHANGED")
        let sameSamples = model.samples.map { DepartureEstimate(departure: $0.departure, driving: $0.driving + 60) }
        let sameModel = TarasRulerModel(batch: TrafficBatch(routeID: model.batch.routeID,
            checkedAt: model.batch.checkedAt.addingTimeInterval(180), samples: sameSamples), limits: model.limits,
            suggestedDeparture: model.suggestion.departure, calendar: model.calendar)!
        let same = snapshot(watch, model: sameModel)
        let removedModel = TarasRulerModel(batch: TrafficBatch(routeID: model.batch.routeID,
            checkedAt: model.batch.checkedAt.addingTimeInterval(180), samples: Array(changedSamples.prefix(5))),
            limits: model.limits, suggestedDeparture: model.samples[4].departure, calendar: model.calendar)!
        let removed = snapshot(suggested, model: removedModel)
        let offline = snapshot(paused, pause: "PAUSED · NO CONNECTION")
        let asleep = snapshot(paused, pause: "PAUSED · MAC ASLEEP")
        let failed = snapshot(paused, feedback: "CHECK FAILED")
        let expired = ready
        return [
            Transition(name: "4.1-open", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.openDuration, path: .open),
            Transition(name: "4.1-close", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.closeDuration, path: .close),
            Transition(name: "4.3-check-start", from: ready, to: check0, cause: .checkingStarted, duration: TarasMotion.ui),
            Transition(name: "4.3-markers-0-to-2", from: check0, to: check2, cause: .checkingProgress, duration: TarasMotion.grow),
            Transition(name: "4.3-markers-6-to-7", from: check6, to: check7, cause: .checkingProgress, duration: TarasMotion.grow),
            Transition(name: "4.4-recheck-start", from: paused, to: recheck0, cause: .checkingStarted, duration: TarasMotion.dim),
            Transition(name: "4.4-recheck-markers", from: recheck0, to: recheck2, cause: .checkingProgress, duration: TarasMotion.grow),
            Transition(name: "4.4-recheck-settle", from: recheck7, to: checkedAgain, cause: .batchSettled),
            Transition(name: "4.5-settle-suggested", from: check7, to: suggested, cause: .batchSettled),
            Transition(name: "4.5-settle-no-fit", from: snapshot(noFit, state: .checking, checking: true, received: 2), to: noFit, cause: .batchSettled),
            Transition(name: "4.6-drag", from: suggested, to: suggested, cause: .scrubStep, duration: TarasMotion.glide, path: .drag, endIndex: 5, preview: true),
            Transition(name: "4.7-park", from: suggested, to: suggested, cause: .park, duration: TarasMotion.glide + TarasMotion.morph, path: .park, endIndex: 5, preview: true),
            Transition(name: "4.7-keyboard-edge", from: suggested, to: suggested, cause: .park, duration: TarasMotion.glide + TarasMotion.morph, path: .park, endIndex: 6, preview: true),
            Transition(name: "4.8-return", from: suggested, to: suggested, cause: .returnHome, duration: TarasMotion.home + TarasMotion.morph, path: .home, startIndex: 1),
            Transition(name: "4.8-watching-return", from: watch, to: watch, cause: .returnHome, duration: TarasMotion.home + TarasMotion.morph, path: .home, startIndex: 5),
            Transition(name: "4.9-use-to-watching", from: suggested, to: checkedAgain, cause: .commit, duration: TarasMotion.morph),
            Transition(name: "4.9-parked-commit", from: suggested, to: delayed, cause: .commit, duration: TarasMotion.morph, startIndex: 5),
            Transition(name: "4.10-wrap-up", from: watch, to: wrap, cause: .phase, duration: TarasMotion.washIn),
            Transition(name: "4.10-leave-now", from: wrap, to: leave, cause: .phase, duration: TarasMotion.washIn),
            Transition(name: "4.10-missed", from: leave, to: missed, cause: .phase, duration: TarasMotion.dim),
            Transition(name: "4.11-delay-checking", from: watch, to: plusChecking, cause: .feedback, duration: TarasMotion.ui),
            Transition(name: "4.11-delay-landed", from: plusChecking, to: delayed, cause: .delayLanded),
            Transition(name: "4.11-delay-rejected", from: watch, to: rejected, cause: .feedback, duration: TarasMotion.ui),
            Transition(name: "4.11-feedback-clears", from: rejected, to: watch, cause: .feedback, duration: TarasMotion.ui),
            Transition(name: "4.12-refresh-same", from: watch, to: same, cause: .batchRefreshed, duration: TarasMotion.roll),
            Transition(name: "4.12-traffic-changed", from: watch, to: changed, cause: .batchRefreshed),
            Transition(name: "4.13-batch-dragging", from: suggested, to: changed, cause: .batchRefreshed, duration: TarasMotion.grow, startIndex: 3, endIndex: 3, preview: true),
            Transition(name: "4.13-batch-parked", from: suggested, to: changed, cause: .batchRefreshed, duration: TarasMotion.grow, startIndex: 5, endIndex: 5, preview: true),
            Transition(name: "4.13-park-removed", from: suggested, to: removed, cause: .park, duration: TarasMotion.glide + TarasMotion.morph, path: .park, startIndex: 5, endIndex: 4, preview: true),
            Transition(name: "4.14-paused", from: watch, to: paused, cause: .paused, duration: TarasMotion.dim),
            Transition(name: "4.14-stale", from: watch, to: stale, cause: .paused, duration: TarasMotion.dim),
            Transition(name: "4.14-park-paused", from: watch, to: paused, cause: .paused, startIndex: 5),
            Transition(name: "4.14-park-stale", from: watch, to: stale, cause: .paused, startIndex: 5),
            Transition(name: "4.14-offline", from: watch, to: offline, cause: .paused, duration: TarasMotion.dim),
            Transition(name: "4.14-asleep", from: watch, to: asleep, cause: .paused, duration: TarasMotion.dim),
            Transition(name: "4.14-check-failed", from: recheck0, to: failed, cause: .paused, duration: TarasMotion.dim),
            Transition(name: "4.15-leaving", from: watch, to: watch, cause: .opened, duration: TarasMotion.closeDuration, path: .close),
            Transition(name: "4.15-stop", from: watch, to: ready, cause: .ended),
            Transition(name: "4.15-expired", from: watch, to: expired, cause: .ended),
            Transition(name: "4.17-bar-hover", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, endIndex: 5),
            Transition(name: "4.17-capsule-press", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.hoverOut, path: .press),
            Transition(name: "4.17-ruler-focus", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.ui, path: .focus),
            Transition(name: "4.17-gear-hover", from: watch, to: watch, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, control: "gear"),
            Transition(name: "4.17-circle-hover", from: watch, to: watch, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, control: "circle"),
            Transition(name: "4.17-capsule-hover", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, control: "capsule"),
            Transition(name: "4.17-gear-focus", from: watch, to: watch, cause: .opened, duration: TarasMotion.ui, path: .focus, control: "gear"),
            Transition(name: "4.17-circle-focus", from: watch, to: watch, cause: .opened, duration: TarasMotion.ui, path: .focus, control: "circle"),
            Transition(name: "4.17-capsule-focus", from: suggested, to: suggested, cause: .opened, duration: TarasMotion.ui, path: .focus, control: "capsule"),
            Transition(name: "4.17-green-capsule-hover", from: leave, to: leave, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, control: "capsule"),
            Transition(name: "4.17-green-capsule-press", from: leave, to: leave, cause: .opened, duration: TarasMotion.hoverOut, path: .press),
            Transition(name: "4.17-disabled-circle-hover", from: leave, to: leave, cause: .opened, duration: TarasMotion.hoverIn, path: .hover, control: "circle")
        ]
    }

    static func panel(_ item: Transition, fraction: Double, reduced: Bool, directory: URL) throws {
        let elapsed = item.duration * fraction
        var scene = TarasRulerScene(snapshot: item.from)
        if let index = item.startIndex, let model = item.from.scrubModel {
            scene.ruler.jump(to: model.samples[index].departure.timeIntervalSinceReferenceDate / 60)
        }
        scene.receive(item.to, change: item.cause, at: 0, previewing: item.preview, reduced: reduced)
        let targetModel = item.to.scrubModel
        switch item.path {
        case .park, .home:
            if let model = targetModel {
                let target = item.path == .home ? model.suggestion.departure : model.samples[item.endIndex!].departure
                scene.ruler.retarget(target.timeIntervalSinceReferenceDate / 60, at: 0,
                    response: item.path == .home ? TarasMotion.home : TarasMotion.glide,
                    damping: item.path == .home ? 1 : 0.9, reduced: reduced)
            }
        case .drag:
            if let model = targetModel, let end = item.endIndex {
                let start = model.suggestion.departure.timeIntervalSinceReferenceDate / 60
                let target = model.samples[end].departure.timeIntervalSinceReferenceDate / 60
                scene.ruler.jump(to: start + (target - start) * fraction)
            }
        default: break
        }
        scene.advance(to: elapsed)
        let selection: Int?
        if item.path == .drag, let model = targetModel {
            selection = model.nearestSampleIndex(offset: (model.suggestion.departure.timeIntervalSinceReferenceDate / 60 - scene.ruler.position) * model.pointsPerMinute)
        } else { selection = item.preview ? item.endIndex : nil }
        var frame = TarasPanelMotionFrame(scene: scene, previous: item.from, elapsed: elapsed, change: item.cause,
                                         selectedIndex: selection)
        if let start = item.startIndex, let oldModel = item.from.scrubModel {
            frame.previousRows = oldModel.rows(at: start, now: item.from.now, state: item.from.state,
                committedDeparture: item.from.committedDeparture, preparationAlreadyUnderway: item.from.preparationAlreadyUnderway)
            if item.from.state != .watching, let rows = frame.previousRows {
                frame.previousCapsule = "USE " + rows[0].value + (item.from.state == .noFit ? " · " + rows[3].status : "")
            }
        }
        frame.reducedMotion = reduced
        frame.hoveredIndex = item.path == .hover && fraction > 0 ? item.endIndex : nil
        frame.pressed = item.path == .press && fraction < 1
        frame.focused = item.path == .focus && item.control == nil && fraction > 0
        frame.hoveredControl = item.path == .hover && fraction > 0 ? item.control : nil
        frame.focusedControl = item.path == .focus && fraction > 0 ? item.control : nil
        let alpha = item.path == .open ? TarasMotion.easeOut(fraction) : item.path == .close ? 1 - pow(fraction, 3) : 1
        let view = TarasPanelView(snapshot: item.to, acceptsInput: false, change: item.cause, motionFrame: frame)
            .opacity(alpha)
        let name = item.name + "-" + String(format: "%03dms", Int((elapsed * 1000).rounded())) + ".png"
        // Setup and the first check have no selected time; every other state shows the cursor.
        let expectCursor = item.to.state != .noRoute && (!item.to.isChecking || item.to.checkingKeepsEvidence)
        try save(view, to: directory.appendingPathComponent(name), width: 360, height: 401,
                 expectCursor: item.path == .open || item.path == .close ? nil : expectCursor)
        records.append(["file": reduced ? "reduce-motion/" + name : name,
                        "section": String(item.name.split(separator: "-")[0]), "timeSeconds": elapsed,
                        "fraction": fraction, "reduceMotion": reduced,
                        "from": String(describing: item.from.state), "to": String(describing: item.to.state),
                        "cause": String(describing: item.cause), "cursorMinutes": scene.ruler.position,
                        "barCount": scene.bars.count, "kind": "panel fixture with shared motion geometry"])
    }

    static func statusItems(directory: URL, reduced: Bool) throws {
        let snapshots = TarasPanelFixtures.all.filter { ["watching-waiting", "wrap-up-now", "leave-now", "missed", "paused", "checking-5-of-7", "no-journey"].contains($0.name) }
        for (name, snapshot) in snapshots {
            let view = HStack(spacing: 5) {
                Canvas { context, _ in
                    for (x, top, height) in [(1.5, 9.0, 5.0), (4.5, 9.0, 5.0), (7.3, 2.0, 12.0),
                                             (10.1, 9.0, 5.0), (13.1, 9.0, 5.0)] {
                        context.fill(Path(roundedRect: CGRect(x: x, y: top, width: 1.4, height: height), cornerRadius: 0.7), with: .color(.white))
                    }
                }.frame(width: 16, height: 16)
                Text(snapshot.menuTitle.trimmingCharacters(in: .whitespaces)).font(.system(size: 13)).monospacedDigit()
            }.foregroundStyle(.white).frame(width: 360, height: 28, alignment: .trailing).padding(.trailing, 12)
                .frame(width: 360, height: 28).background(Color(white: 0.12))
            let file = "4.2-status-\(name)-000ms.png"
            try save(view, to: directory.appendingPathComponent(file), width: 360, height: 28)
            records.append(["file": reduced ? "reduce-motion/" + file : file, "section": "4.2", "timeSeconds": 0,
                            "reduceMotion": reduced, "title": snapshot.menuTitle, "kind": "static status title reference; system glyph needs live check"])
        }
    }

    static func widgets(directory: URL, reduced: Bool) throws {
        for (name, entry) in PlanWidgetFixtures.all {
            for small in [true, false] {
                let width = small ? 170 : 364, height = 170
                let model = PlanWidgetModel(entry: entry, calendar: PlanWidgetFixtures.calendar)
                let view = TarasWidgetView(model: model, small: small).frame(width: CGFloat(width), height: CGFloat(height))
                    .background(TarasWidgetView.background).clipShape(RoundedRectangle(cornerRadius: 22))

                let file = "4.16-widget-\(name)-\(small ? "small" : "medium")-000ms.png"
                try save(view, to: directory.appendingPathComponent(file), width: width, height: height)
                records.append(["file": reduced ? "reduce-motion/" + file : file, "section": "4.16", "timeSeconds": 0,
                                "reduceMotion": reduced, "entry": name, "kind": "production widget endpoint; WidgetKit supplies opacity and numeric transitions"])
            }
        }
    }

    static func save<V: View>(_ view: V, to url: URL, width: Int, height: Int, expectCursor: Bool? = nil) throws {
        try autoreleasepool {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw failure("ImageRenderer failed for \(url.lastPathComponent)") }
            guard image.width == width * 2 && image.height == height * 2 else {
                throw failure("Incorrect dimensions \(image.width) × \(image.height) for \(url.lastPathComponent)")
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let expectCursor {
                guard let cursor = bitmap.colorAt(x: 359, y: 20)?.usingColorSpace(.deviceRGB),
                      (cursor.redComponent > 0.9 && cursor.greenComponent > 0.3 && cursor.greenComponent < 0.5
                       && cursor.blueComponent < 0.3) == expectCursor else {
                    throw failure("Unexpected orange cursor visibility in \(url.lastPathComponent); expected \(expectCursor)")
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("PNG failed") }
            try png.write(to: url, options: .atomic)
        }
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "CaptureTarasMotion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
