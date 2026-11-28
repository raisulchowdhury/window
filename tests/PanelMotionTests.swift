import Foundation

@MainActor
enum PanelMotionTests {
    static func run() -> Int {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { print("FAIL: \(message)"); exit(1) }; count += 1
        }
        var spring = RulerMotion(position: 0)
        spring.retarget(10, at: 0, response: PanelMotion.home, damping: 1)
        spring.advance(to: 0.055)
        expect(spring.position > 2 && spring.position < 4, "return covers about a third in 55ms")
        var last = spring.position
        for frame in 4...28 {
            spring.advance(to: Double(frame) / 60)
            expect(spring.position >= last && spring.position <= 10, "home is monotonic, with no overshoot")
            last = spring.position
        }
        expect(!spring.isMoving && spring.position == 10 && spring.velocity == 0, "spring rests by 450ms")
        var longReturn = RulerMotion(position: 157)
        longReturn.retarget(0, at: 0, response: PanelMotion.home, damping: 1)
        longReturn.advance(to: PanelMotion.home)
        expect(longReturn.isMoving && longReturn.position > 1, "home does not snap its remaining two points at response cutoff")
        longReturn.advance(to: PanelMotion.maxTravel - 0.00001)
        expect(longReturn.position < 0.6, "home gets close before its 450ms cutoff")
        var glide = RulerMotion(position: 0)
        glide.retarget(10, at: 0, response: PanelMotion.glide)
        glide.advance(to: PanelMotion.glide)
        expect(!glide.isMoving && glide.position == 10, "park keeps its approved 320ms cutoff")
        spring.retarget(30, at: 1, response: PanelMotion.glide)
        spring.advance(to: 1.1)
        let before = spring
        spring.retarget(5, at: 1.1, response: PanelMotion.glide)
        expect(spring.position == before.position && spring.velocity == before.velocity, "key repeat retargets from visible position and velocity")
        spring.jump(to: spring.position)
        expect(!spring.isMoving && spring.velocity == 0, "pointer takes over without travel")
        spring.retarget(100, at: 2, response: PanelMotion.glide, reduced: true)
        spring.advance(to: 2.075)
        expect(spring.position < 100, "Reduce Motion has a short ease-out")
        spring.advance(to: 2.151)
        expect(spring.position == 100 && !spring.isMoving, "Reduce Motion travel ends at 150ms")
        spring.jump(to: .nan)
        expect(spring.position == 100, "nonfinite motion target ignored")
        var capsule = CapsuleState()
        capsule.update("WATCH 17:30", at: 0, opened: true)
        expect(capsule.accepts(at: 0), "opening never input-locks current content")
        capsule.update("I'M LEAVING", at: 1)
        expect(!capsule.accepts(at: 1.599) && capsule.accepts(at: 1.6), "label change locks action for 600ms")
        capsule.update("I'M LEAVING", at: 2)
        expect(capsule.accepts(at: 2), "unchanged label never restarts lock")
        for label in ["WATCH 17:30", "CHECK TIMES", "CHECK AGAIN", "EDIT TIMES", "SET ROUTE"] {
            expect(CapsuleState.returnMayActivate(label), "Return accepts safe action \(label)")
        }
        for label in ["I'M LEAVING", "Stop", "CHECKING"] {
            expect(!CapsuleState.returnMayActivate(label), "Return never ends a watch or triggers \(label)")
        }
        let snapshot = PanelFixtures.all[2].snapshot
        let old = snapshot.model!
        var scrub = ScrubState()
        scrub.send(.park(5), model: old)
        let changedSamples = old.samples.map { DepartureEstimate(departure: $0.departure, driving: $0.driving + 120) }
        let next = RulerModel(batch: TrafficBatch(routeID: old.batch.routeID, checkedAt: old.batch.checkedAt.addingTimeInterval(180), samples: changedSamples), limits: old.limits, suggestedDeparture: old.samples[3].departure, calendar: old.calendar)!
        let departure = old.samples[5].departure
        expect(scrub.accessibilityValue(in: old, now: snapshot.now).hasSuffix("5 minutes later than suggested."),
               "VoiceOver reports parked offset with Mac hint kept separately")
        expect(!scrub.rebase(from: old, to: next), "same parked departure stays after changed suggestion")
        expect(next.samples[scrub.selectedIndex(in: next)].departure == departure, "rebase holds absolute cursor time")
        expect(next.rows(at: scrub.selectedIndex(in: next), now: snapshot.now)[2].value == "32 min", "park reads new batch numbers")
        let removed = RulerModel(batch: TrafficBatch(routeID: old.batch.routeID, checkedAt: old.batch.checkedAt, samples: Array(changedSamples.prefix(5))), limits: old.limits, suggestedDeparture: old.samples[3].departure, calendar: old.calendar)!
        expect(scrub.rebase(from: next, to: removed) && scrub.parkedIndex == 4, "removed parked sample glides to nearest new sample")
        scrub.send(.home, model: old)
        expect(scrub.send(.escape, model: old) == .none, "second Esc has no home work and reaches panel close")
        scrub.send(.step(1), model: old)
        expect(!scrub.escapeReturnsHome(canScrub: false), "paused or checking parked Esc closes instead of getting stuck")
        expect(scrub.escapeReturnsHome(canScrub: true), "available parked ruler Esc returns home")
        expect(scrub.send(.escape, model: old) == .home && !scrub.isPreviewing, "first Esc returns a park")
        scrub.send(.edge(true), model: old)
        expect(scrub.parkedIndex == old.samples.count - 1, "option right parks last")
        scrub.send(.edge(false), model: old)
        expect(scrub.parkedIndex == 0, "option left parks first")
        scrub.send(.home, model: old)
        scrub.send(.press(x: 180, y: 0), model: old)
        scrub.send(.drag(-6), model: old)
        scrub.send(.releaseProjected(-300), model: old)
        expect(scrub.parkedIndex == 5, "release uses 100ms velocity projection")
        scrub.send(.press(x: 180, y: 0), model: old)
        scrub.send(.drag(10), model: old)
        let absolute = old.suggestion.departure.timeIntervalSinceReferenceDate / 60 - scrub.offset / old.pointsPerMinute
        scrub.rebase(from: old, to: next)
        expect(abs(next.suggestion.departure.timeIntervalSinceReferenceDate / 60 - scrub.offset / next.pointsPerMinute - absolute) < 0.00001, "batch during drag holds time under pointer")
        let rebasedOffset = scrub.offset
        scrub.send(.drag(11), model: next)
        expect(abs(scrub.offset - rebasedOffset - 1) < 0.0001, "continued drag remains 1:1 after batch")
        var bars = BarMotion(departure: departure, height: 20, opacity: 0.6)
        bars.retarget(height: 40, opacity: 1, at: 0, duration: PanelMotion.grow, reduced: false)
        bars.advance(to: 0.12)
        expect(bars.height > 20 && bars.height < 40 && bars.opacity > 0.6, "markers grow to final evidence")
        bars.advance(to: 0.24)
        expect(bars.height == 40 && bars.opacity == 1 && !bars.isMoving, "bars stop without idle timeline")
        bars.retarget(height: 25, opacity: 0.3, at: 1, duration: PanelMotion.grow, reduced: true)
        expect(bars.height == 25, "Reduce Motion bar height changes without growth")
        bars.advance(to: 1.121)
        expect(bars.opacity == 0.3 && !bars.isMoving, "Reduce Motion bar fades in 120ms")
        var scene = RulerScene(snapshot: snapshot)
        let changed = RulerModel.PanelSnapshot(state: .suggested, limits: snapshot.limits, now: snapshot.now, calendar: snapshot.calendar, model: next)
        let cursor = scene.ruler.position
        scene.receive(changed, change: .batchRefreshed, at: 0, previewing: true, reduced: false)
        scene.advance(to: 0.45)
        expect(scene.ruler.position == cursor, "batch never moves ruler under pointer")
        expect(scene.bars.count == next.samples.count && !scene.isMoving, "refresh retargets in place then rests")
        let traffic = RulerModel.PanelSnapshot(state: .suggested, limits: snapshot.limits, now: snapshot.now,
            model: next, feedbackLabel: "TRAFFIC CHANGED")
        expect(PanelChange.classify(previous: PanelFixtures.all[3].snapshot, next: traffic) == .batchRefreshed,
               "traffic changed feedback keeps the data settle cause")
        let checking = PanelFixtures.all[1].snapshot
        var firstCheck = RulerScene(snapshot: PanelFixtures.noJourney)
        firstCheck.receive(checking, change: .checkingStarted, at: 0, previewing: false, reduced: false)
        expect(firstCheck.ruler.position == RulerScene.center(checking).timeIntervalSinceReferenceDate / 60 && firstCheck.band.position == firstCheck.ruler.position,
               "first check hard-cuts to midpoint with no premature orange band")
        expect(RulerScene(snapshot: checking).bars.allSatisfy { $0.height == 20 && $0.opacity == 0.6 }, "checking uses only uniform markers")
        let retained = RulerModel.PanelSnapshot(state: .checking, limits: snapshot.limits, now: snapshot.now,
            model: old, expectedCount: 7, checkingKeepsEvidence: true)
        var recheckScene = RulerScene(snapshot: retained)
        let arrived = RulerModel.PanelSnapshot(state: .checking, limits: snapshot.limits, now: snapshot.now,
            model: old, expectedCount: 7, receivedCount: 1, checkingKeepsEvidence: true, checkingSamples: [old.samples[0]])
        recheckScene.receive(arrived, change: .checkingProgress, at: 0, previewing: false, reduced: false)
        expect(recheckScene.retiringBars.count == 1 && recheckScene.bars.first(where: { $0.departure == old.samples[0].departure })?.height == 0,
               "recheck grows a separate marker while old matched evidence fades")
        recheckScene.advance(to: PanelMotion.reducedFade)
        expect(recheckScene.retiringBars.isEmpty, "matched old evidence disappears after 120ms")
        recheckScene.advance(to: PanelMotion.grow)
        expect(recheckScene.bars.first(where: { $0.departure == old.samples[0].departure })?.height == 20,
               "replacement marker lands at uniform 20pt")
        for reduced in [false, true] {
            for source in [checking, retained] {
                var settleScene = RulerScene(snapshot: source)
                settleScene.receive(changed, change: .batchSettled, at: 0, previewing: false, reduced: reduced)
                for time in [0, 0.055, 0.15, 0.20, 0.32, 0.45] {
                    if time == 0.055 {
                        for cause in [PanelChange.clockTick, .feedback] {
                            settleScene.receive(changed, change: cause, at: time, previewing: false, reduced: reduced)
                        }
                    }
                    settleScene.advance(to: time)
                    expect(settleScene.band == settleScene.ruler,
                           "fresh and retained settles keep a zero-width band at \(time), reduced=\(reduced)")
                }
                expect(settleScene.ruler.position == RulerScene.center(changed).timeIntervalSinceReferenceDate / 60,
                       "settle reaches the suggestion")
            }
        }
        var dimBar = BarMotion(departure: departure, height: 30, opacity: 1)
        dimBar.retarget(height: 30, opacity: 0.3, at: 0, duration: PanelMotion.dim, reduced: true, dimming: true)
        dimBar.advance(to: 0.15)
        expect(abs(dimBar.opacity - 0.65) < 0.0001 && dimBar.isMoving,
               "Reduce Motion keeps the 300ms ease-in-out dim fade")
        var landing = LandingState()
        expect(!landing.receive(.batchSettled) && landing.isHolding, "batch starts one delayed landing")
        expect(landing.receive(.clockTick) && landing.isHolding, "clock preserves landing cause, old rows and announcement")
        expect(landing.receive(.feedback) && landing.isHolding, "permission feedback preserves delayed landing")
        expect(landing.receive(.batchSettled) && landing.isHolding, "repeated settle publish never restages checking")
        landing.finish()
        expect(!landing.receive(.clockTick) && !landing.isHolding, "finished landing accepts normal clock updates")
        _ = landing.receive(.batchSettled)
        expect(!landing.receive(.paused) && !landing.isHolding, "real pause interrupts the delayed landing")
        let paused = PanelFixtures.all.first { $0.snapshot.state == .paused }!.snapshot
        expect(PanelChange.classify(previous: paused, next: paused) == .clockTick, "paused tick never announces resumed")
        let stale = RulerModel.PanelSnapshot(state: .stale, limits: snapshot.limits, now: snapshot.now, model: old)
        for reduced in [false, true] {
            for destination in [paused, stale, retained, snapshot] {
                let cause: PanelChange = destination.state == .checking ? .checkingStarted : destination.state == .suggested ? .resumed : .paused
                var parkedScene = RulerScene(snapshot: snapshot)
                let target = RulerScene.center(destination).timeIntervalSinceReferenceDate / 60
                parkedScene.ruler.jump(to: target + 5)
                parkedScene.receive(destination, change: cause, at: 0, previewing: false, reduced: reduced)
                expect(parkedScene.ruler.position == target + 5 && parkedScene.ruler.isMoving,
                       "cleared park returns without jumping on \(cause)")
                var expectedHome = RulerMotion(position: target + 5)
                expectedHome.retarget(target, at: 0, response: PanelMotion.home, damping: 1, reduced: reduced)
                for time in [0, 0.055, 0.15, 0.20, 0.36, 0.45] {
                    if time == 0.055 {
                        for update in [PanelChange.clockTick, .feedback, .checkingProgress] {
                            parkedScene.receive(destination, change: update, at: time, previewing: false, reduced: reduced)
                        }
                    }
                    parkedScene.advance(to: time); expectedHome.advance(to: time)
                    expect(parkedScene.ruler == expectedHome && parkedScene.band == parkedScene.ruler,
                           "cleared park follows home with a zero-width band on \(cause), reduced=\(reduced)")
                }
                expect(parkedScene.ruler.position == target && !parkedScene.ruler.isMoving,
                       "cleared park rests at the plan")
            }
        }
        expect(PanelChange.classify(previous: stale, next: stale) == .clockTick, "stale tick never announces resumed")
        expect(PanelChange.classify(previous: paused, next: snapshot) == .resumed, "actual recovery still announces resumed")
        var announcement = AnnouncementState()
        announcement.receive(.batchSettled)
        expect(announcement.accepts("Checked again."), "first check announced")
        expect(!announcement.accepts("Checked again."), "duplicate in one cause suppressed")
        announcement.receive(.checkingStarted); announcement.receive(.batchSettled)
        expect(announcement.accepts("Checked again."), "same result of second check announced")
        for frame in 0...180 {
            let t = Double(frame) / 1000
            let opacity = PanelMotion.textOpacities(at: t)
            expect(opacity.old == 0 || opacity.new == 0, "sequential text never overlaps at \(frame)ms")
        }
        expect(PanelMotion.textOpacities(at: 0).old == 1 && PanelMotion.textOpacities(at: 0.18).new > 0.999,
               "text uses full 60ms out and 120ms in")
        return count
    }
}
