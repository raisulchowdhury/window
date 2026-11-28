import SwiftUI
import AppKit

/// Keeps the scroll target the same size as its value control.
struct ScrollAdjustableTime: ViewModifier {
    @Binding var value: Int
    var bounds: ClosedRange<Int>
    func body(content: Content) -> some View {
        content.background {
                GeometryReader { geometry in
                    ScrollTimeAdjustment(value: $value, bounds: bounds)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
    }
}

/// A background event observer preserves the SwiftUI button's click and focus behavior.
struct ScrollTimeAdjustment: NSViewRepresentable {
    @Binding var value: Int
    var bounds: ClosedRange<Int> = 0...1439
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> ScrollTarget { ScrollTarget() }
    func updateNSView(_ view: ScrollTarget, context: Context) {
        view.enabled = enabled
        view.adjust = { count in value = TimeScrollAccumulator.adjusted(value, steps: count, bounds: bounds) }
    }
    static func dismantleNSView(_ view: ScrollTarget, coordinator: ()) { view.stop() }
    final class ScrollTarget: NSView {
        var adjust: ((Int) -> Void)?
        var monitor: Any?
        var accumulator = TimeScrollAccumulator()
        var enabled = true
        var gesture = ScrollEditSession()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let owner = self.window
                let inside = owner != nil && event.window === owner && !self.isHiddenOrHasHiddenAncestor
                    && self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil))
                let canEdit = self.enabled && owner?.isKeyWindow == true && owner?.attachedSheet == nil
                let vertical = event.scrollingDeltaY.isFinite && event.scrollingDeltaX.isFinite
                    && event.scrollingDeltaY != 0 && abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                let phase: ScrollEditSession.Phase
                if !event.momentumPhase.isEmpty { phase = .momentum }
                else if event.phase.contains(.began) { phase = .began }
                else if event.phase.contains(.cancelled) { phase = .cancelled }
                else if event.phase.contains(.ended) { phase = .ended }
                else if event.phase.isEmpty { phase = .discrete }
                else { phase = .changed }
                let decision = self.gesture.handle(phase, inside: inside, enabled: canEdit, vertical: vertical,
                    stationary: event.scrollingDeltaY == 0 && event.scrollingDeltaX == 0)
                if phase == .began || decision == .passThrough { self.accumulator = TimeScrollAccumulator() }
                switch decision {
                case .passThrough: return event
                case .consume: return nil
                case .adjust:
                    let count = self.accumulator.steps(delta: event.scrollingDeltaY,
                        precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp)
                    if count != 0 { self.adjust?(count) }
                    return nil
                }
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; gesture = ScrollEditSession(); accumulator = TimeScrollAccumulator() }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

#if !WINDOW_NATIVE
struct SettlingDotTime: View {
    let text: String
    let color: Color
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var morph = DotMorph()
    private var cells: Int { max(0, text.reduce(0) { $0 + DotTime.advance($1) } - 1) }
    private func mask(_ value: String) -> [Double] {
        let width = max(0, value.reduce(0) { $0 + DotTime.advance($1) } - 1)
        var values = [Double](repeating: 0, count: width * 7)
        var x = 0
        for character in value {
            for (row, line) in (DotTime.glyphs[character] ?? []).enumerated() {
                for (column, bit) in line.enumerated() where bit == "1" {
                    if x + column < width { values[row * width + x + column] = 1 }
                }
            }
            x += DotTime.advance(character)
        }
        return values
    }
    var body: some View {
        // Parse glyphs once per view update, not once per animation frame.
        let target = mask(text)
        return TimelineView(.animation(paused: !morph.running || reduceMotion || !appearsActive)) { _ in
            let values = morph.target.count == target.count ? morph.values(at: WindowMotionClock.now) : target
            let cell = height / 7
            Canvas { context, _ in
                guard cells > 0 else { return }
                for (index, amount) in values.enumerated() where amount > 0 {
                    let diameter = cell * 0.75 * (0.45 + 0.55 * amount)
                    let row = index / cells, column = index % cells
                    var dot = context; dot.opacity = amount
                    dot.fill(Path(ellipseIn: CGRect(x: CGFloat(column) * cell + (cell - diameter) / 2,
                        y: CGFloat(row) * cell + (cell - diameter) / 2, width: diameter, height: diameter)), with: .color(color))
                }
            }.frame(width: CGFloat(cells) * cell, height: height)
        }
        .accessibilityHidden(true).transaction { $0.animation = nil }
        .onAppear { morph.move(to: mask(text), at: WindowMotionClock.now, animated: false) }
        .onChange(of: text) { old, new in
            let sameLayout = old.count == new.count && old.firstIndex(of: ":")?.utf16Offset(in: old) == new.firstIndex(of: ":")?.utf16Offset(in: new)
            morph.move(to: mask(new), at: WindowMotionClock.now, animated: sameLayout && !reduceMotion && appearsActive)
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { morph.finish() } }
        .onChange(of: appearsActive) { _, active in if !active { morph.finish() } }
        .task(id: morph.motionID) {
            guard let id = morph.motionID else { return }
            let remaining = max(0, min(DotMorph.duration,
                DotMorph.duration - WindowMotionClock.now.timeIntervalSince(morph.started)))
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            morph.finish(id) // An old completion cannot settle a newer target.
        }
        .onDisappear { morph.finish() }
    }
}

#endif
