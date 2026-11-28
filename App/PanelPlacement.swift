import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct PanelPlacement {
    enum Path: String { case statusItem = "status-item", fallback = "main-screen-top-right" }
    let origin: CGPoint
    let path: Path

    /// The panel never sits closer than this to the left or right edge of the visible frame.
    static let edgeMargin: CGFloat = 8

    static func resolve(buttonFrame: CGRect?, screenFrame: CGRect?, visibleFrame: CGRect) -> Self {
        let left = visibleFrame.minX + edgeMargin
        // On a frame too narrow for both margins the left one wins, so the panel's own left edge stays reachable.
        let right = max(left, visibleFrame.maxX - 360 - edgeMargin)
        let top = max(visibleFrame.minY, visibleFrame.maxY - 6 - 401)
        if let buttonFrame, !buttonFrame.isEmpty, buttonFrame.midY >= visibleFrame.maxY,
           screenFrame?.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)) != false {
            let x = min(max(buttonFrame.midX - 180, left), right)
            let y = max(visibleFrame.minY, min(top, buttonFrame.minY - 6 - 401))
            return Self(origin: CGPoint(x: x, y: y), path: .statusItem)
        }
        return Self(origin: CGPoint(x: right, y: top), path: .fallback)
    }
}
