import AppKit
import SwiftUI
import WindowCore

@main
@MainActor
struct CaptureStates {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = PanelFixtures.noJourney
        let ready = RulerModel.PanelSnapshot(state: .noRoute, limits: base.limits, now: base.now,
            calendar: base.calendar, routeTitle: "North Campus → Harbor Terminal", readyForToday: true)
        let stopped = RulerModel.PanelSnapshot(state: .noRoute, limits: base.limits, now: base.now,
            calendar: base.calendar, routeTitle: "Office → Home", readyForToday: true, undoStopAvailable: true)
        for (name, snapshot) in PanelFixtures.all + [("ready-long-route", ready), ("stopped-undo", stopped)] {
            let renderer = ImageRenderer(content: PanelView(snapshot: snapshot, acceptsInput: false))
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                throw NSError(domain: "CaptureStates", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "ImageRenderer failed for \(name)"])
            }
            guard image.width == 720 && image.height == 802 else {
                throw NSError(domain: "CaptureStates", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Wrong dimensions for \(name): \(image.width) × \(image.height)"])
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "CaptureStates", code: 3)
            }
            let path = output.appendingPathComponent(name + ".png")
            try png.write(to: path, options: .atomic)
            print(path.path)
        }
    }
}
