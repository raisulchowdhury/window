import AppKit
import SwiftUI
import WidgetKit
import WindowCore

@main
@MainActor
struct CaptureTarasWidgets {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for fixture in PlanWidgetFixtures.all {
            for small in [true, false] {
                for vibrant in [false, true] {
                    let width = small ? 170 : 364
                    let view = TarasWidgetView(model: PlanWidgetModel(entry: fixture.entry, calendar: PlanWidgetFixtures.calendar), small: small)
                        .environment(\.widgetRenderingMode, vibrant ? .vibrant : .fullColor)
                        .frame(width: CGFloat(width), height: 170)
                        .background(TarasWidgetView.background)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage, image.width == width * 2, image.height == 340 else {
                        throw NSError(domain: "CaptureTarasWidgets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Wrong render dimensions: \(fixture.name)"])
                    }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "CaptureTarasWidgets", code: 2)
                    }
                    let name = "widget-\(small ? "small" : "medium")-\(fixture.name)\(vibrant ? "-vibrant" : "").png"
                    let path = output.appendingPathComponent(name)
                    try png.write(to: path, options: .atomic)
                    print(path.path)
                }
            }
        }
        // ImageRenderer exercises our monochrome branch; macOS's compositing still needs a desktop check.
        print("Vibrant captures use the vibrant environment; verify system compositing on the desktop.")
    }
}
