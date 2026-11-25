import SwiftUI
import WindowCore

extension TarasMotion {
    static func rollAnimation(reduced: Bool) -> Animation { reduced ? .easeOut(duration: reducedFade) : .snappy(duration: roll) }
    static let wordAnimation = Animation.easeInOut(duration: word)
    static let uiAnimation = Animation.easeOut(duration: ui)
    static let morphAnimation = Animation.snappy(duration: morph)
    static let growAnimation = Animation.easeOut(duration: grow)
    static let dimAnimation = Animation.easeInOut(duration: dim)
    static func washAnimation(incoming: Bool) -> Animation { .easeInOut(duration: incoming ? washIn : washOut) }
    static func popAnimation(reduced: Bool) -> Animation { reduced ? .easeOut(duration: reducedFade) : .spring(response: pop, dampingFraction: 0.8) }
    static func hoverAnimation(incoming: Bool) -> Animation { .easeOut(duration: incoming ? hoverIn : hoverOut) }
}
