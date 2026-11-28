import AppKit
import SwiftUI
import WindowCore

/// AppKit exposes wheel notches, momentum phases and pointer velocity.
struct RulerInput: NSViewRepresentable {
    var send: (ScrubState.Event) -> Void
    var pointer: (Bool) -> Void = { _ in }
    var hover: (Double?, Double?) -> Void = { _, _ in }
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.send = send; view.pointer = pointer; view.hover = hover }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stopMonitoring() }

    final class InputView: NSView {
        var send: (ScrubState.Event) -> Void = { _ in }
        var pointer: (Bool) -> Void = { _ in }
        var hover: (Double?, Double?) -> Void = { _, _ in }
        private var monitor: Any?
        private var tracking: NSTrackingArea?
        private var startX: CGFloat = 0
        private var lastX: CGFloat = 0
        private var lastTime: TimeInterval = 0
        private var velocity: Double = 0
        private var scrollTranslation: CGFloat = 0
        private var scrolling = false
        private var scrollEnd: Timer?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseMoved(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil); hover(p.x, p.y)
        }
        override func mouseExited(with event: NSEvent) { hover(nil, nil) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, event.window === self.window,
                      event.modifierFlags.intersection([.command, .control]).isEmpty else { return event }
                if event.keyCode == 53 { self.pointer(false); self.send(.escape); return nil }
                // SwiftUI handles keys when its focus ring owns the ruler; this path is for a mouse press.
                guard self.window?.firstResponder === self else { return event }
                self.pointer(false)
                switch event.keyCode {
                case 123: self.send(event.modifierFlags.contains(.option) ? .edge(false) : .step(-1))
                case 124: self.send(event.modifierFlags.contains(.option) ? .edge(true) : .step(1))
                case 36, 76: self.send(.use)
                case 48: self.window?.selectNextKeyView(self); return nil
                default: return event
                }
                return nil
            }
        }
        func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; scrollEnd?.invalidate(); scrollEnd = nil }
        override func mouseDown(with event: NSEvent) {
            scrollEnd?.invalidate(); scrolling = false
            window?.makeFirstResponder(self); pointer(true)
            let p = convert(event.locationInWindow, from: nil)
            startX = p.x; lastX = p.x; lastTime = event.timestamp; velocity = 0
            send(.press(x: p.x, y: p.y))
        }
        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if event.timestamp > lastTime { velocity = 0.7 * velocity + 0.3 * Double(x - lastX) / (event.timestamp - lastTime) }
            lastX = x; lastTime = event.timestamp
            send(.drag(x - startX))
        }
        override func mouseUp(with event: NSEvent) {
            send(.releaseProjected(event.timestamp - lastTime <= PanelMotion.velocitySampleMaxAge ? velocity : 0))
        }
        override func scrollWheel(with event: NSEvent) {
            pointer(true)
            if event.hasPreciseScrollingDeltas {
                guard event.momentumPhase.isEmpty else { return }
                if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
                    scrollEnd?.invalidate(); if scrolling { send(.release) }; scrolling = false; return
                }
                guard event.scrollingDeltaX != 0 else { return }
                if !scrolling {
                    scrollTranslation = 0; scrolling = true
                    send(.press(x: 180, y: 0))
                }
                scrollTranslation += event.scrollingDeltaX; send(.drag(scrollTranslation))
                if event.phase.isEmpty {
                    scrollEnd?.invalidate()
                    scrollEnd = Timer.scheduledTimer(withTimeInterval: PanelMotion.scrollEndDelay, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.scrolling else { return }
                            self.send(.release); self.scrolling = false
                        }
                    }
                }
            } else {
                let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
                if delta != 0 { send(.step(delta > 0 ? -1 : 1)) }
            }
        }
    }
}
