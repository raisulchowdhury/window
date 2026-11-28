import AppKit
import SwiftUI
import WindowCore

@MainActor
enum AnimatedTextTests {
    private final class Input: ObservableObject {
        @Published var text = "A"
    }
    private struct Probe: View {
        @ObservedObject var input: Input
        var body: some View {
            AnimatedText(text: input.text, numeric: false, animate: true)
                .font(.system(size: 30)).foregroundStyle(.white)
                .frame(width: 100, height: 50).background(.black)
        }
    }
    static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let input = Input()
        let host = NSHostingView(rootView: Probe(input: input))
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 50)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func capture() -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        func brightness(_ bitmap: NSBitmapImageRep) -> Double {
            var total = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    total += color.redComponent * color.alphaComponent
                }
            }
            return total
        }
        _ = capture()
        try await Task.sleep(for: .milliseconds(40))
        let visible = brightness(capture())
        precondition(visible > 0, "initial A must be visible")
        let clock = ContinuousClock(), started = ContinuousClock.now
        input.text = "B"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let fading = capture()
        input.text = "A"
        let reversalTime = clock.now - started
        precondition(reversalTime < .seconds(PanelMotion.textOut), "A→B→A must happen within 60ms")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
        let restored = capture()
        // Read the captured pixels after both snapshots, outside the timed input sequence.
        precondition(brightness(fading) < visible * 0.9, "B starts fading A before its 60ms replacement")
        precondition(brightness(restored) >= visible * 0.95, "A→B→A within 60ms immediately restores opacity without animation")
        try await Task.sleep(for: .milliseconds(150))
        precondition(abs(brightness(capture()) - visible) < visible * 0.05, "cancelled B never replaces or hides restored A")
        print("PASS: 5 native animated text checks (A→B→A in \(reversalTime); offscreen host; no Window launch)")
    }
}
