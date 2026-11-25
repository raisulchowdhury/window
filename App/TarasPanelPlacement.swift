import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct TarasPanelPlacement {
    enum Path: String { case statusItem = "status-item", fallback = "main-screen-top-right" }
    let origin: CGPoint
    let path: Path

    static func resolve(buttonFrame: CGRect?, screenFrame: CGRect?, visibleFrame: CGRect) -> Self {
        let right = max(visibleFrame.minX, visibleFrame.maxX - 360)
        let top = max(visibleFrame.minY, visibleFrame.maxY - 6 - 401)
        if let buttonFrame, !buttonFrame.isEmpty, buttonFrame.midY >= visibleFrame.maxY,
           screenFrame?.contains(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)) != false {
            let x = min(max(buttonFrame.midX - 180, visibleFrame.minX), right)
            let y = max(visibleFrame.minY, min(top, buttonFrame.minY - 6 - 401))
            return Self(origin: CGPoint(x: x, y: y), path: .statusItem)
        }
        return Self(origin: CGPoint(x: right, y: top), path: .fallback)
    }
}
