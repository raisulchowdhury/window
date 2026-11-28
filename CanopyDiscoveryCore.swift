import Foundation

/// Decorative state only. No journey, clock, permissions, storage or services.
enum CanopyDiscoveryPolicy {
    static func canPlay(watching: Bool, busy: Bool, needsAttention: Bool,
                        choosing: Bool, editing: Bool, presenting: Bool) -> Bool {
        !busy && !editing && !presenting && (!watching || (!needsAttention && !choosing))
    }
    static func canOpenCover(watching: Bool, editing: Bool, presenting: Bool, busy: Bool = false) -> Bool {
        !watching && !editing && !presenting && !busy
    }
}

struct CanopyBirdPose: Equatable, Codable {
    var facing = 1.0
    var position = 0.0             // Two authored perches, not random coordinates.
    var lift = 0.0
    var stretch = 1.0
    var tilt = 0.0
    var eyeOpen = true
    var branchBend = 0.0
}

struct CanopyBirdState {
    enum Kind { case hop, glance, wake }
    struct Motion {
        let id = UUID()
        let kind: Kind
        let start: TimeInterval
        let from: Int
        let to: Int
        let initialTilt: Double
        let initialTiltVelocity: Double
        var duration: TimeInterval {
            switch kind { case .hop: return 0.52; case .glance: return 0.72; case .wake: return 0.90 }
        }
    }
    private(set) var facing = 1
    private(set) var perch = 0
    private(set) var awakeInStillMode = false
    private(set) var motion: Motion?

    /// Repeated presses coalesce, rather than queueing movement behind the user.
    @discardableResult mutating func activate(at uptime: TimeInterval, dark: Bool,
                                              reducedMotion: Bool) -> Bool {
        guard uptime.isFinite else { return false }
        settleElapsedMotion(at: uptime)
        // A deliberate press outranks hover feedback, but never queues hops.
        let initialTilt = motion?.kind == .glance ? pose(at: uptime, dark: dark).tilt : 0
        let initialVelocity: Double
        if let motion, motion.kind == .glance {
            let elapsed = max(0, uptime - motion.start)
            initialVelocity = -7 * Double(facing) * sin(2 * .pi * elapsed / motion.duration) * .pi / motion.duration
        } else { initialVelocity = 0 }
        if motion?.kind == .glance { motion = nil }
        guard motion == nil else { return false }
        if reducedMotion {
            if dark { awakeInStillMode.toggle() } else { facing = perch == 0 ? 1 : -1; perch = 1 - perch }
        } else {
            awakeInStillMode = false
            motion = Motion(kind: dark ? .wake : .hop, start: uptime,
                            from: perch, to: dark ? perch : 1 - perch,
                            initialTilt: initialTilt, initialTiltVelocity: initialVelocity)
        }
        return true
    }
    @discardableResult mutating func notice(at uptime: TimeInterval, dark: Bool,
                                            reducedMotion: Bool) -> Bool {
        guard uptime.isFinite, !dark, !reducedMotion else { return false }
        settleElapsedMotion(at: uptime)
        guard motion == nil else { return false }
        motion = Motion(kind: .glance, start: uptime, from: perch, to: perch, initialTilt: 0, initialTiltVelocity: 0)
        return true
    }
    private mutating func settleElapsedMotion(at uptime: TimeInterval) {
        if let motion, uptime - motion.start >= motion.duration { finish(motion.id) }
    }
    mutating func finish(_ id: UUID? = nil) {
        guard let motion, id == nil || motion.id == id else { return }
        perch = motion.to
        if motion.kind == .hop { facing = motion.to > motion.from ? 1 : -1 }
        self.motion = nil
    }
    mutating func settleForEnvironmentChange() { finish(); awakeInStillMode = false }
    mutating func reset() { perch = 0; facing = 1; awakeInStillMode = false; motion = nil }
    var perchDescription: String { perch == 0 ? "On the left branch" : "On the right branch" }

    func pose(at uptime: TimeInterval, dark: Bool) -> CanopyBirdPose {
        var pose = CanopyBirdPose(facing: Double(facing), position: Double(perch), eyeOpen: !dark || awakeInStillMode)
        guard let motion, uptime.isFinite else { return pose }
        let elapsed = max(0, uptime - motion.start)
        if motion.kind == .hop { pose.facing = motion.to > motion.from ? 1 : -1 }
        if elapsed >= motion.duration {
            pose.position = Double(motion.to)
            return pose
        }
        switch motion.kind {
        case .hop:
            if elapsed < 0.08 {
                let p = elapsed / 0.08
                let eased = p * p * (3 - 2 * p)
                pose.stretch = 1 - 0.10 * eased
                // Hermite handoff carries hover angular velocity into anticipation.
                pose.tilt = motion.initialTilt * (1 - eased)
                    + motion.initialTiltVelocity * 0.08 * (p * p * p - 2 * p * p + p)
            } else if elapsed < 0.36 {
                let progress = (elapsed - 0.08) / 0.28
                let eased = progress * progress * (3 - 2 * progress)
                pose.position = Double(motion.from) + Double(motion.to - motion.from) * eased
                pose.lift = 9 * sin(.pi * progress)
                let stretchProgress = min(1, progress * 5)
                pose.stretch = 0.90 + 0.10 * stretchProgress * stretchProgress * (3 - 2 * stretchProgress)
                pose.tilt = Double(motion.to - motion.from) * 6 * pow(sin(.pi * progress), 2)
            } else {
                let progress = (elapsed - 0.36) / 0.16
                pose.position = Double(motion.to)
                let landing = pow(sin(.pi * progress), 2)
                pose.stretch = 1 - 0.08 * landing
                pose.branchBend = 0.8 * landing
            }
        case .glance:
            pose.tilt = -7 * pose.facing * pow(sin(.pi * elapsed / motion.duration), 2)
        case .wake:
            pose.eyeOpen = elapsed >= 0.12 && elapsed < 0.70
        }
        return pose
    }
}

/// One geometry source feeds both the native Canvas and the SVG review proof.
/// Coordinates are local to a 34 × 28 point drawing, with the feet on y = 27.
struct CanopyPathCommand: Codable {
    let op: String
    let values: [Double]
    init(_ op: String, _ values: Double...) { self.op = op; self.values = values }
}
enum CanopyBirdGeometry {
    static let body = [
        CanopyPathCommand("M", 2, 7), CanopyPathCommand("L", 10, 14),
        CanopyPathCommand("C", 12, 10, 16, 9, 20, 10),
        CanopyPathCommand("C", 19, 5, 22, 2, 26, 3),
        CanopyPathCommand("C", 29, 3, 30, 6, 29, 9),
        CanopyPathCommand("L", 33, 10), CanopyPathCommand("L", 29, 12),
        CanopyPathCommand("C", 29, 20, 24, 24, 17, 23),
        CanopyPathCommand("C", 10, 23, 7, 19, 2, 7), CanopyPathCommand("Z")
    ]
    static let wing = [CanopyPathCommand("M", 12, 15), CanopyPathCommand("Q", 19, 12, 23, 15),
                       CanopyPathCommand("Q", 19, 21, 12, 15), CanopyPathCommand("Z")]
    static let feet = [CanopyPathCommand("M", 17, 22), CanopyPathCommand("L", 17, 27),
                       CanopyPathCommand("L", 14, 27), CanopyPathCommand("M", 22, 22),
                       CanopyPathCommand("L", 23, 27), CanopyPathCommand("L", 26, 27)]
    static let closedEye = [CanopyPathCommand("M", 25, 8), CanopyPathCommand("Q", 26.5, 9.5, 28, 8)]
}

enum WindowBuildInscription {
    static func label(version: String?, build: String?) -> String {
        func clean(_ string: String?) -> String? {
            guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 64,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        let version = clean(version), build = clean(build)
        let title = version.map { "Version " + $0 } ?? "Development build"
        return build.map { title + " · " + $0 } ?? title
    }
    static func source(_ value: String?) -> String? {
        guard let value, value.count == 64,
              value.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { return nil }
        return "Source " + value.prefix(12).lowercased()
    }
}
