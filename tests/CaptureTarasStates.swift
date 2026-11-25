import AppKit
import SwiftUI
import WindowCore

@main
@MainActor
struct CaptureTarasStates {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = TarasPanelFixtures.noJourney
        let ready = TarasRulerModel.PanelSnapshot(state: .noRoute, limits: base.limits, now: base.now,
            calendar: base.calendar, routeTitle: "North Campus → Harbor Terminal", readyForToday: true)
        let stopped = TarasRulerModel.PanelSnapshot(state: .noRoute, limits: base.limits, now: base.now,
            calendar: base.calendar, routeTitle: "Office → Home", readyForToday: true, undoStopAvailable: true)
        for (name, snapshot) in TarasPanelFixtures.all + [("ready-long-route", ready), ("stopped-undo", stopped)] {
            let renderer = ImageRenderer(content: TarasPanelView(snapshot: snapshot, acceptsInput: false))
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                throw NSError(domain: "CaptureTarasStates", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "ImageRenderer failed for \(name)"])
            }
            guard image.width == 720 && image.height == 802 else {
                throw NSError(domain: "CaptureTarasStates", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Wrong dimensions for \(name): \(image.width) × \(image.height)"])
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "CaptureTarasStates", code: 3)
            }
            let path = output.appendingPathComponent(name + ".png")
            try png.write(to: path, options: .atomic)
            print(path.path)
        }
    }
}
