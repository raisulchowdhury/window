import Foundation

/// A reversed fade invalidates its predecessor's completion before it can hide the panel.
public struct PanelFade: Equatable {
    public enum Phase { case closed, opening, open, closing }
    public private(set) var phase = Phase.closed
    public private(set) var generation = 0
    public init() {}

    @discardableResult
    public mutating func open() -> Int {
        generation += 1
        phase = .opening
        return generation
    }

    @discardableResult
    public mutating func close() -> Int? {
        guard phase != .closed && phase != .closing else { return nil }
        generation += 1
        phase = .closing
        return generation
    }

    @discardableResult
    public mutating func complete(_ token: Int) -> Bool {
        guard token == generation else { return false }
        switch phase {
        case .opening: phase = .open
        case .closing: phase = .closed
        case .closed, .open: return false
        }
        return true
    }
}
