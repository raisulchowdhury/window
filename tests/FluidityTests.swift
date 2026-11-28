import Foundation
#if WINDOW_CORE_TESTS
@testable import WindowCore
#endif

#if !WINDOW_CORE_TESTS
@main
#endif
struct FluidityTests {
    static var checks = 0
    static var failures = 0
    static func expect(_ value: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !value() { failures += 1; print("FAIL: \(name)") }
    }
    static func near(_ a: Double, _ b: Double, tolerance: Double = 0.002) -> Bool {
        a.isFinite && b.isFinite && abs(a - b) <= tolerance
    }
    static let epoch = Date(timeIntervalSinceReferenceDate: 1000)
    static func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
    static func main() {
        // Start and redirect the production renderer without depending on a frame callback.
        var dots = DotMorph()
        dots.move(to: [0, 1, 0], at: at(0), animated: false)
        dots.move(to: [1, 1, 0], at: at(0), animated: true)
        let interrupt = 0.1, h = 0.00001
        let before = dots.values(at: at(interrupt))
        let speedBefore = (before[0] - dots.values(at: at(interrupt - h))[0]) / h
        dots.move(to: [0, 1, 1], at: at(interrupt), animated: true)
        let speedAfter = (dots.values(at: at(interrupt + h))[0] - dots.values(at: at(interrupt))[0]) / h
        expect(zip(before, dots.values(at: at(interrupt))).allSatisfy { near($0, $1, tolerance: 0.000001) }, "redirect preserves every visible dot")
        expect(near(speedBefore, speedAfter, tolerance: 0.01), "redirect preserves dot velocity, not only its position")
        expect(before == dots.values(at: at(interrupt)), "redirect frame preserves exact amounts, including rounding")
        expect(dots.values(at: at(interrupt))[1] == 1, "unchanged dot stays exactly lit")

        var same = DotMorph()
        same.move(to: [0], at: at(0), animated: false)
        same.move(to: [1], at: at(0), animated: true)
        let started = same.started
        let reference = same
        same.move(to: [1], at: at(0.1), animated: true)
        expect(same.started == started, "same-target refresh does not restart motion")
        expect(same.values(at: at(0.2)) == reference.values(at: at(0.2)), "same-target refresh preserves its future trajectory")

        // A click interrupts hover at the current angular speed, not just tilt.
        var bird = CanopyBirdState()
        _ = bird.notice(at: 0, dark: false, reducedMotion: false)
        let click = 0.18
        let tilt = bird.pose(at: click, dark: false).tilt
        let angularBefore = (tilt - bird.pose(at: click - h, dark: false).tilt) / h
        _ = bird.activate(at: click, dark: false, reducedMotion: false)
        let angularAfter = (bird.pose(at: click + h, dark: false).tilt - bird.pose(at: click, dark: false).tilt) / h
        expect(near(tilt, bird.pose(at: click, dark: false).tilt), "click preserves tilt")
        expect(near(angularBefore, angularAfter, tolerance: 0.04), "click preserves angular velocity")
        for edge in [0.08, 0.36, 0.52] {
            let left = bird.pose(at: click + edge - h, dark: false)
            let center = bird.pose(at: click + edge, dark: false)
            let right = bird.pose(at: click + edge + h, dark: false)
            expect(near((center.stretch - left.stretch)/h, (right.stretch - center.stretch)/h, tolerance: 0.02), "stretch handoff at \(edge) has no speed step")
            expect(near((center.tilt - left.tilt)/h, (right.tilt - center.tilt)/h, tolerance: 0.04), "tilt handoff at \(edge) has no speed step")
            expect(near((center.branchBend - left.branchBend)/h, (right.branchBend - center.branchBend)/h, tolerance: 0.04), "branch handoff at \(edge) has no speed step")
        }

        // Dense input across different sample cadences must stay bounded and deterministic.
        var cadenceReference: [Double]?
        for fps in [30, 60, 120] {
            var motion = DotMorph()
            motion.move(to: [0, 1], at: at(0), animated: false)
            var minimum = 1.0, maximum = 0.0, time = 0.0
            for input in 0..<120 {
                let value = Double(input % 2)
                motion.move(to: [value, 1], at: at(time), animated: true)
                for frame in 0...4 {
                    let values = motion.values(at: at(time + Double(frame)/Double(fps)))
                    minimum = min(minimum, values[0]); maximum = max(maximum, values[0])
                    expect(values[1] == 1, "unchanged pixel at \(fps) Hz")
                }
                time += 0.019 + Double(input % 7) * 0.003
            }
            expect(minimum >= 0 && maximum <= 1, "opacity stays inside gamut at \(fps) Hz")
            let final = motion.values(at: at(time + 1))
            expect(final == motion.target, "delayed callback cannot keep old dots visible")
            if let cadenceReference { expect(final == cadenceReference, "same result at every display cadence") }
            cadenceReference = final
        }
        var noMotion = DotMorph()
        noMotion.move(to: [0, 1], at: at(0), animated: false)
        noMotion.move(to: [1, 0], at: at(0), animated: true)
        noMotion.finish()
        expect(!noMotion.running && noMotion.values(at: at(0)) == [1, 0], "Reduce Motion settles immediately")
        noMotion.move(to: [0, 1, 0], at: at(0), animated: true)
        expect(!noMotion.running, "changed digit layout never morphs unrelated columns")
        // Independently integrate the second-order ODE rather than duplicating
        // the production closed form. x'' + 56 x' + 784 x = 784 target.
        var oracle = DotMorph()
        oracle.move(to: [0], at: at(0), animated: false)
        var x = 0.0, velocity = 0.0, t = 0.0
        let dt = 0.0001
        func acceleration(_ x: Double, _ v: Double, _ target: Double) -> Double {
            784 * (target - x) - 56 * v
        }
        for segment in 0..<12 {
            let target = segment % 3 == 0 ? 1.0 : segment % 3 == 1 ? 0.0 : 0.35
            oracle.move(to: [target], at: at(t), animated: true)
            for step in 0..<370 {
                let k1x = velocity, k1v = acceleration(x, velocity, target)
                let k2x = velocity + dt*k1v/2, k2v = acceleration(x + dt*k1x/2, velocity + dt*k1v/2, target)
                let k3x = velocity + dt*k2v/2, k3v = acceleration(x + dt*k2x/2, velocity + dt*k2v/2, target)
                let k4x = velocity + dt*k3v, k4v = acceleration(x + dt*k3x, velocity + dt*k3v, target)
                x += dt*(k1x + 2*k2x + 2*k3x + k4x)/6
                velocity += dt*(k1v + 2*k2v + 2*k3v + k4v)/6
                t += dt
                if step % 37 == 0 {
                    expect(near(oracle.values(at: at(t))[0], x, tolerance: 0.0000001), "motion agrees with independently integrated dynamics")
                }
            }
        }
        // Completion belongs to a specific transition, never just to a text value.
        let obsoleteID = oracle.motionID!
        oracle.move(to: [0.9], at: at(t), animated: true)
        let latestID = oracle.motionID!
        oracle.finish(obsoleteID)
        expect(oracle.running && oracle.motionID == latestID, "obsolete completion cannot stop a newer transition")
        oracle.finish(latestID)
        expect(!oracle.running && oracle.motionID == nil, "current completion releases display updates")
        let accepted = oracle.target
        oracle.move(to: [.nan], at: at(t), animated: true)
        oracle.move(to: [2], at: at(t), animated: true)
        oracle.move(to: [0], at: Date(timeIntervalSinceReferenceDate: .infinity), animated: true)
        expect(oracle.target == accepted, "invalid inputs do not destroy an accepted glyph")
        oracle.move(to: [0], at: at(0), animated: false)
        oracle.move(to: [1], at: at(0), animated: true)
        let justBeforeTail = oracle.values(at: at(DotMorph.duration - 0.0000001))[0]
        expect(1 - justBeforeTail < 1.0/8192, "finite cutoff has a bounded subvisible opacity tail")
        expect(oracle.values(at: at(DotMorph.duration)) == [1], "finite cutoff returns the exact final mask")
        let firstID = oracle.motionID
        oracle.move(to: [1], at: at(2), animated: true)
        expect(!oracle.running && firstID != nil, "duplicate after elapsed motion releases the display schedule")
        let monotonicBefore = WindowMotionClock.now
        let monotonicAfter = WindowMotionClock.now
        expect(monotonicAfter >= monotonicBefore, "display clock progresses independently of civil dates")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) fluidity assertions; \(failures) failures. Mathematical motion checks, not native visual approval.")
        if failures > 0 { exit(1) }
    }
}
