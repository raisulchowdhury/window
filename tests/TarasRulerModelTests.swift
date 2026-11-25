import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
@MainActor
struct TarasRulerModelTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        func time(_ hour: Int, _ minute: Int) -> Date { day.addingTimeInterval(Double(hour * 60 + minute) * 60) }
        let now = time(16, 58)
        let limits = WatchLimits(earliest: time(17, 10), latest: time(17, 40), homeBy: time(18, 15), packing: 600)
        let samples = [41, 40, 37, 33, 31, 30, 30].enumerated().map {
            DepartureEstimate(departure: time(17, 10 + $0.offset * 5), driving: Double($0.element * 60))
        }
        let batch = TrafficBatch(routeID: "office-home", checkedAt: now, samples: samples)
        let nearNow = time(17, 0).addingTimeInterval(-1)
        let nearDates = DeparturePolicy.candidates(now: nearNow, limits: limits, committed: nil)
        let flatTraffic = nearDates.map { DepartureEstimate(departure: $0, driving: 1800) }
        expect(DeparturePolicy.recommend(flatTraffic, limits: limits, now: nearNow.addingTimeInterval(2), committed: nil)?.departure == time(17, 11),
               "a check crossing the readiness minute can still recommend the next checked minute")
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let springForward = pacific.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let skippedTime = SavedJourney(earliest: 60, latest: 110, homeBy: 150)
        expect(skippedTime.limits(on: springForward, calendar: pacific) == nil, "a nonexistent deadline is not silently moved")
        let suggested = DeparturePolicy.recommend(samples, limits: limits, now: now, committed: nil)!
        let model = TarasRulerModel(batch: batch, limits: limits, suggestedDeparture: suggested.departure, calendar: calendar)!
        expect(suggested.departure == time(17, 30), "core suggests 17:30")
        expect(model.minutesPerTick == 1 && model.majorTickMinutes == 15, "30 minutes uses 1-minute ticks")
        for (minutes, unit, major) in [(50, 1, 15), (51, 2, 30), (100, 2, 30), (101, 5, 60), (180, 5, 60)] {
            let wide = WatchLimits(earliest: limits.earliest, latest: limits.earliest.addingTimeInterval(Double(minutes * 60)),
                                   homeBy: time(22, 0), packing: 600)
            let scaled = TarasRulerModel(batch: batch, limits: wide, suggestedDeparture: suggested.departure, calendar: calendar)!
            expect(scaled.minutesPerTick == unit && scaled.majorTickMinutes == major, "tick scale at \(minutes) minutes")
            expect(scaled.x(for: suggested.departure) == 180, "scaled suggestion at cursor")
            expect(scaled.nearestSampleIndex(offset: -30 / Double(unit)) == 5, "scaled drag selects returned 17:35")
            expect(scaled.rubberBand(offset: -10000) == -60 / Double(unit) - 24, "scaled lower rubber bound")
        }
        let ticks = model.ticks(offset: -30)
        expect(ticks.allSatisfy { (3...357).contains($0.x) }, "ticks stay within reference edges")
        expect(zip(ticks, ticks.dropFirst()).allSatisfy { abs($1.x - $0.x - 6) < 0.001 }, "ticks 6 points apart")
        expect(ticks.contains { $0.date == time(17, 30) && $0.isMajor && $0.height == 30 && $0.x == 150 }, "major tick follows drag")
        expect(ticks.contains { $0.date == time(17, 9) && $0.dim && $0.height == 15 }, "outside ticks dim")
        expect(ticks.contains { $0.date == limits.earliest && !$0.dim }, "window boundary tick stays bright")
        let bars = model.bars(offset: -30)
        expect(bars.count == samples.count && bars.map(\.index) == Array(samples.indices), "one bar per returned sample")
        for (index, height) in [50.0, 20 + 300.0 / 11, 20 + 210.0 / 11, 20 + 90.0 / 11, 20 + 30.0 / 11, 20, 20].enumerated() {
            expect(abs(bars[index].height - height) < 0.00001, "bar height \(index)")
        }
        expect(bars[4].x == 150 && bars[5].x == 180, "bars and ticks share positions")
        expect(bars.map(\.dim) == [false, false, false, false, false, false, true], "only 17:40 exceeds cushion")
        let equalBatch = TrafficBatch(routeID: "equal", checkedAt: now, samples: samples.map { DepartureEstimate(departure: $0.departure, driving: 1800) })
        let equal = TarasRulerModel(batch: equalBatch, limits: limits, suggestedDeparture: suggested.departure, calendar: calendar)!
        expect(equal.bars().allSatisfy { $0.height == 20 }, "equal drives have 20-point bars")
        for (offset, index, header) in [(0.0, 4, "SUGGESTED"), (-30, 5, "+5M"), (120, 0, "−20M"), (-60, 6, "+10M"), (1, 4, "±0M"), (-15, 4, "±0M")] {
            expect(model.nearestSampleIndex(offset: offset) == index, "nearest sample at \(offset)")
            expect(model.headerText(offset: offset) == header, "header at \(offset)")
        }
        expect(model.headerText(offset: 0, parked: true) == "±0M", "parked suggestion is active")
        expect(model.rubberBand(offset: 130) == 123.5, "right resistance")
        expect(model.rubberBand(offset: -70) == -63.5, "left resistance")
        expect(model.rubberBand(offset: 10000) == 144, "right rubber max 24")
        expect(model.rubberBand(offset: -10000) == -84, "left rubber max 24")
        expect(model.nearestSampleIndex(offset: -84) == 6 && model.nearestSampleIndex(offset: 144) == 0, "overscroll selects endpoints")
        expect(model.dragOffset(translation: 2) == nil && model.dragOffset(translation: -2) == nil, "2 points remains a click")
        expect(model.dragOffset(translation: 3) == 3, "3 points starts drag")
        expect(model.dragOffset(translation: 2, hasMoved: true) == 2, "drag does not become click again")
        expect(model.dragOffset(translation: 30, from: 120) == 130.5, "drag from parked position")
        expect(model.bandSpan(offset: -30) == 150...180 && model.bandSpan(offset: 120) == 180...300, "band from cursor to moved suggestion")
        expect(model.bandSpan(offset: 0.5) == nil, "subpixel band hidden")
        expect(model.offset(forSampleAt: 5) == -30 && model.offset(forSampleAt: 99) == nil, "park uses actual sample")
        let empty = TrafficBatch(routeID: "empty", checkedAt: now, samples: [])
        expect(TarasRulerModel(batch: empty, limits: limits, suggestedDeparture: suggested.departure) == nil, "empty batch has no ruler")
        expect(TarasRulerModel(batch: batch, limits: limits, suggestedDeparture: time(17, 31)) == nil, "unreturned suggestion rejected")

        typealias Row = TarasRulerModel.Row
        let suggestedRows = [
            Row(label: "+20M VS 17:10", status: "WAIT 32M", glyph: .hour, name: "Leave", value: "17:30", anchor: true),
            Row(label: "−10M · WRAP-UP TIME", status: "IN 22M", glyph: .ringO, name: "Wrap up", value: "17:20"),
            Row(label: "APPLE MAPS", status: "10M LESS DRIVING", glyph: .down, name: "Drive", value: "31 min"),
            Row(label: "10M LATER · ARRIVE BY 18:15", status: "14M SPARE", glyph: .check, name: "Arrive around", value: "18:01")
        ]
        expect(model.rows(at: 4, now: now) == suggestedRows, "mapping A exact suggestion rows")
        let firstRows = model.rows(at: 0, now: now)
        expect(firstRows[0].label == "EARLIEST CHECKED", "earliest checked label")
        expect(firstRows[2] == Row(label: "APPLE MAPS", status: "LONGEST DRIVE", glyph: .flat, name: "Drive", value: "41 min"), "longest drive row")
        expect(firstRows[3].label == "ARRIVE BY 18:15" && firstRows[3].status == "24M SPARE", "baseline arrival has no comparison")
        for (index, status, glyph) in [(1, "SIMILAR", TarasRulerModel.Glyph.flat), (2, "SIMILAR", .flat), (3, "8M LESS DRIVING", .down)] {
            let row = model.rows(at: index, now: now)[2]
            expect(row.status == status && row.glyph == glyph, "driving status threshold at sample \(index)")
        }
        let cushion = model.rows(at: 6, now: now)
        expect(cushion[3].status == "INSIDE CUSHION" && cushion[3].glyph == .warn && cushion[3].value == "18:10", "17:40 inside cushion")
        expect(cushion.allSatisfy(\.valDim) && cushion.allSatisfy { !$0.nameDim && !$0.dim }, "infeasible values dim, names remain readable")
        expect(model.rows(at: 6, now: now, keepBright: true).allSatisfy { !$0.valDim }, "explicit recovery preview stays bright")
        expect(model.rows(at: -1, now: now).isEmpty, "invalid row index has no synthetic data")

        // Each phase-table row, including the one-minute grace and zero packing.
        let phases: [(Date, String, TarasRulerModel.Glyph, String, TarasRulerModel.Glyph, Bool, Bool)] = [
            (now, "WAIT 32M", .hour, "IN 22M", .ringO, false, false),
            (time(17, 20), "WAIT 10M", .hour, "WRAP UP NOW", .orange, false, false),
            (time(17, 22), "WAIT 8M", .hour, "WRAP UP NOW", .orange, false, false),
            (time(17, 30), "LEAVE NOW", .green, "DONE", .checkDim, true, true),
            (time(17, 30).addingTimeInterval(59), "LEAVE NOW", .green, "DONE", .checkDim, true, true),
            (time(17, 31), "PASSED", .cross, "DONE", .checkDim, false, true)
        ]
        for (date, leaveStatus, leaveGlyph, wrapStatus, wrapGlyph, go, wrapDim) in phases {
            let rows = model.rows(at: 4, now: date, state: .watching, committedDeparture: suggested.departure)
            expect(rows[0].status == leaveStatus && rows[0].glyph == leaveGlyph && rows[0].go == go, "Leave phase at \(date)")
            expect(rows[1].status == wrapStatus && rows[1].glyph == wrapGlyph && rows[1].valDim == wrapDim, "Wrap-up phase at \(date)")
            expect(rows[0].valDim == (date >= time(17, 31)), "only missed Leave value dims")
        }
        let parkedDuringWatch = model.rows(at: 0, now: time(17, 12), state: .watching, committedDeparture: suggested.departure)
        expect(parkedDuringWatch[0].status == "PREVIEW" && parkedDuringWatch[1].status == "PREVIEW" && !parkedDuringWatch[0].go,
               "an inspected alternative cannot issue wrap-up or departure instructions")
        let missed = model.rows(at: 4, now: time(17, 31), state: .watching, committedDeparture: suggested.departure)
        expect(missed[0].label == "DEPARTURE TIME PASSED" && missed.allSatisfy(\.valDim), "missed exact label and dim values")
        expect(missed[2].label == "APPLE MAPS" && missed[2].status.isEmpty && missed[2].glyph == .none, "missed drive has no glyph")
        expect(missed[3].label == "ARRIVE BY 18:15" && missed[3].status.isEmpty && missed[3].glyph == .none, "missed arrival has no glyph")
        let underway = model.rows(at: 4, now: now, state: .watching, committedDeparture: suggested.departure, preparationAlreadyUnderway: true)
        expect(underway[1].status == "WRAP UP NOW", "core preparation override preserved")
        for state in [TarasRulerModel.State.paused, .stale] {
            let rows = model.rows(at: 4, now: time(17, 31), state: state, committedDeparture: suggested.departure)
            expect(rows[0].status == "UNCONFIRMED" && rows[0].glyph == .pause && !rows[0].go, "pause gates temporal phase")
            expect(rows[1].status == "ALERTS OFF" && rows[1].glyph == .flat, "pause disables wrap-up cue")
            expect(rows[2].label == (state == .stale ? "AS OF 16:58 · EXPIRED" : "LAST CHECK 16:58") && rows[2].status.isEmpty && rows[2].glyph == .none, "pause names the last check and stale names expiry")
            expect(rows[3].label == suggestedRows[3].label && rows[3].status.isEmpty && rows[3].glyph == .none, "pause retains arrival comparison")
            expect(rows.map(\.value) == suggestedRows.map(\.value) && rows.allSatisfy(\.valDim), "pause retains all last numbers, dimmed")
        }
        let late = TarasRulerModel.recoveryRows(for: DepartureEstimate(departure: time(17, 45), driving: 40 * 60),
                                                original: limits, calendar: calendar)
        expect(late.map(\.name) == ["Leave", "Drive", "Arrive around"] && late.map(\.value) == ["17:45", "40 min", "18:25"],
               "recovery rows use the panel's names and 24-hour times")
        expect(late[0].label == "AFTER YOUR 17:40 LIMIT" && late[0].anchor, "recovery names a departure past the limit")
        expect(late[2].label == "ARRIVE BY 18:15" && late[2].status == "LATE 10M" && late[2].glyph == .red, "recovery late arrival is the only red")
        let tight = TarasRulerModel.recoveryRows(for: DepartureEstimate(departure: time(17, 30), driving: 40 * 60),
                                                 original: limits, calendar: calendar)
        expect(tight[0].label == "BEST LEAVE TIME" && tight[2].status == "5M SPARE" && tight[2].glyph == .warn,
               "recovery with less than the usual spare warns without red")
        let roomy = TarasRulerModel.recoveryRows(for: DepartureEstimate(departure: time(17, 10), driving: 30 * 60),
                                                 original: limits, calendar: calendar)
        expect(roomy[2].status == "35M SPARE" && roomy[2].glyph == .check, "recovery spare time reads like the panel")
        let zeroLimits = WatchLimits(earliest: limits.earliest, latest: limits.latest, homeBy: limits.homeBy, packing: 0)
        let zero = TarasRulerModel(batch: batch, limits: zeroLimits, suggestedDeparture: suggested.departure, calendar: calendar)!
        for state in [TarasRulerModel.State.suggested, .watching] {
            for date in [now, time(17, 30), time(17, 31)] {
                expect(zero.rows(at: 4, now: date, state: state, committedDeparture: suggested.departure)[1] == Row(label: "NO WRAP-UP TIME SET", status: "NOT NEEDED", glyph: .flat, name: "Wrap up", value: "—", valDim: true), "packing zero remains not needed")
            }
        }
        for state in [TarasRulerModel.State.paused, .stale] {
            let watched = zero.rows(at: 4, now: now, state: state, committedDeparture: suggested.departure)[1]
            expect(watched.label == "NO WRAP-UP TIME SET" && watched.status == "ALERTS OFF" && watched.glyph == .flat,
                   "a paused watch without wrap-up still shows that its leave alert is off")
            expect(zero.rows(at: 4, now: now, state: state)[1].status == "NOT NEEDED",
                   "a paused suggestion with alerts allowed has nothing silenced")
            expect(zero.rows(at: 4, now: now, state: state, alertsOff: true)[1].status == "ALERTS OFF",
                   "macOS alerts off shows on a paused suggestion")
            let unwatched = model.rows(at: 4, now: now, state: state)[1]
            expect(unwatched.status.isEmpty && unwatched.glyph == .none, "paused suggestion does not claim alerts are off")
            let denied = model.rows(at: 4, now: now, state: state, alertsOff: true)[1]
            expect(denied.status == "ALERTS OFF" && denied.glyph == .flat, "paused rows show macOS alerts off")
        }
        expect(model.rows(at: 4, now: now, state: .watching, committedDeparture: suggested.departure, alertsOff: true)[1].status == "IN 22M",
               "watching rows keep their cue; the header carries alerts off")
        expect(zero.rows(at: 4, now: now, state: .watching, committedDeparture: suggested.departure)[0].status == "WAIT 32M", "zero packing leaves waiting unchanged")
        expect(zero.rows(at: 4, now: time(17, 30), state: .watching, committedDeparture: suggested.departure)[0].go, "zero packing still leaves now")

        for (homeBy, status, glyph, dim) in [(time(18, 11), "10M SPARE", TarasRulerModel.Glyph.check, false),
                                           (time(18, 1), "INSIDE CUSHION", .warn, true),
                                           (time(18, 0), "LATE 1M", .red, true)] {
            let changed = WatchLimits(earliest: limits.earliest, latest: limits.latest, homeBy: homeBy, packing: limits.packing)
            let preview = TarasRulerModel(batch: batch, limits: changed, suggestedDeparture: suggested.departure, calendar: calendar)!
            let row = preview.rows(at: 4, now: now)[3]
            expect(row.status == status && row.glyph == glyph && row.valDim == dim, "home-by status at \(homeBy)")
        }
        var smallBuffer = limits; smallBuffer.buffer = 300
        let reduced = TarasRulerModel(batch: batch, limits: smallBuffer, suggestedDeparture: suggested.departure, calendar: calendar)!
        expect(reduced.rows(at: 6, now: now)[3].status == "5M SPARE" && !reduced.bars()[6].dim, "rows and bars honor WatchLimits buffer")

        let unorderedBatch = TrafficBatch(routeID: "unordered", checkedAt: now, samples: Array(samples.reversed()))
        let unordered = TarasRulerModel(batch: unorderedBatch, limits: limits, suggestedDeparture: suggested.departure, calendar: calendar)!
        expect(unordered.rows(at: 2, now: now) == suggestedRows, "earliest baseline independent of response order")
        expect(unordered.nearestSampleIndex(offset: -30) == 1, "nearest index preserves returned order")
        expect(unordered.rubberBand(offset: 10000) == 144, "rubber bounds independent of response order")
        let invalidBatch = TrafficBatch(routeID: "invalid", checkedAt: now, samples: [DepartureEstimate(departure: time(17, 30), driving: .nan)])
        expect(TarasRulerModel(batch: invalidBatch, limits: limits, suggestedDeparture: suggested.departure) == nil, "nonfinite drive rejected")

        let secondsBatch = TrafficBatch(routeID: "seconds", checkedAt: now, samples: [
            DepartureEstimate(departure: time(17, 10), driving: 2460),
            DepartureEstimate(departure: time(17, 30), driving: 1990)
        ])
        let secondsModel = TarasRulerModel(batch: secondsBatch, limits: limits, suggestedDeparture: time(17, 30), calendar: calendar)!
        let roundedRows = secondsModel.rows(at: 1, now: now)
        expect(roundedRows[2] == Row(label: "APPLE MAPS", status: "SIMILAR", glyph: .flat,
                                   name: "Drive", value: "33 min"), "470-second saving rounds for display but fails the exact 8-minute test")
        expect(roundedRows[3] == Row(label: "12M LATER · ARRIVE BY 18:15", status: "12M SPARE", glyph: .check,
                                   name: "Arrive around", value: "18:03"), "1990 seconds arrival and spare round independently from exact seconds")
        expect(DeparturePolicy.recommend(secondsBatch.samples, limits: limits, now: now, committed: nil)?.departure == time(17, 10),
               "core still rejects the exact 470-second saving even though the display rounds to 8 minutes")
        for (seconds, drive, arrival, spare, status) in [
            (2010.0, "34 min", "18:04", "12M SPARE", "SIMILAR"),
            (1980.0, "33 min", "18:03", "12M SPARE", "8M LESS DRIVING"),
            (1880.0, "31 min", "18:01", "14M SPARE", "10M LESS DRIVING")
        ] {
            let fractional = TrafficBatch(routeID: "fractional", checkedAt: now, samples: [
                samples[0], DepartureEstimate(departure: time(17, 30), driving: seconds)
            ])
            let model = TarasRulerModel(batch: fractional, limits: limits, suggestedDeparture: time(17, 30), calendar: calendar)!
            let rows = model.rows(at: 1, now: now)
            expect(rows[2].value == drive && rows[2].label == "APPLE MAPS" && rows[2].status == status,
                   "fractional drive comparison at \(seconds) seconds")
            expect(rows[3].value == arrival && rows[3].status == spare, "fractional arrival and spare at \(seconds) seconds")
        }
        let cushionLimits = WatchLimits(earliest: limits.earliest, latest: limits.latest, homeBy: time(18, 11), packing: 600)
        let cushionBatch = TrafficBatch(routeID: "rounded-cushion", checkedAt: now, samples: [
            DepartureEstimate(departure: time(17, 30), driving: 1880)
        ])
        let roundedCushion = TarasRulerModel(batch: cushionBatch, limits: cushionLimits, suggestedDeparture: time(17, 30), calendar: calendar)!
        expect(roundedCushion.rows(at: 0, now: now)[3].status == "INSIDE CUSHION" &&
               roundedCushion.rows(at: 0, now: now).allSatisfy { $0.valDim }, "exact arrival controls cushion and value dimming")
        expect(roundedCushion.bars()[0].opacity == 0.35 && !cushionLimits.fits(cushionBatch.samples[0]),
               "bar dimming agrees with core feasibility at 1880 seconds")
        let roundedTieBatch = TrafficBatch(routeID: "rounded-tie", checkedAt: now, samples: [
            DepartureEstimate(departure: time(17, 10), driving: 2460),
            DepartureEstimate(departure: time(17, 30), driving: 2440)
        ])
        let roundedTie = TarasRulerModel(batch: roundedTieBatch, limits: limits, suggestedDeparture: time(17, 10), calendar: calendar)!
        expect(roundedTie.rows(at: 1, now: now)[2].status == "SIMILAR" &&
               roundedTie.rows(at: 1, now: now)[2].value == "41 min", "longest-drive status uses exact seconds even when displayed minutes tie")

        expect(roundedTie.bars().map(\.height) == [21.25, 20], "bar heights use exact drive seconds even when displayed minutes tie")
        for (seconds, status) in [(1980.001, "SIMILAR"), (1980.0, "8M LESS DRIVING"), (1979.999, "8M LESS DRIVING")] {
            let exactBatch = TrafficBatch(routeID: "exact-threshold", checkedAt: now, samples: [
                samples[0], DepartureEstimate(departure: time(17, 30), driving: seconds)
            ])
            let exact = TarasRulerModel(batch: exactBatch, limits: limits, suggestedDeparture: time(17, 30), calendar: calendar)!
            expect(exact.rows(at: 1, now: now)[2].status == status, "exact driving threshold at \(seconds) seconds")
        }
        let exactLateLimits = WatchLimits(earliest: limits.earliest, latest: limits.latest,
            homeBy: time(18, 1).addingTimeInterval(10), packing: 600)
        let exactLate = TarasRulerModel(batch: cushionBatch, limits: exactLateLimits, suggestedDeparture: time(17, 30), calendar: calendar)!
        expect(exactLate.rows(at: 0, now: now)[3].status == "LATE 1M" && exactLate.rows(at: 0, now: now)[3].glyph == .red,
               "ten seconds late is still late despite arrival clock rounding")

        let noRoute = [
            Row(label: "SET A ROUTE TO BEGIN", status: "", glyph: .none, name: "Leave", value: "—", anchor: true, valDim: true),
            Row(label: "WRAP-UP TIME", status: "", glyph: .none, name: "Wrap up", value: "10 min", valDim: true),
            Row(label: "APPLE MAPS", status: "", glyph: .none, name: "Drive", value: "—", valDim: true),
            Row(label: "ARRIVE BY 18:15", status: "", glyph: .none, name: "Arrive around", value: "—", valDim: true)
        ]
        let checking = [
            Row(label: "WINDOW 17:10–17:40", status: "CHECKING", glyph: .dots, name: "Leave", value: "––:––", anchor: true, valDim: true),
            Row(label: "−10M · WRAP-UP TIME", status: "", glyph: .none, name: "Wrap up", value: "––:––", valDim: true),
            Row(label: "APPLE MAPS", status: "", glyph: .none, name: "Drive", value: "–– min", valDim: true),
            Row(label: "ARRIVE BY 18:15", status: "", glyph: .none, name: "Arrive around", value: "––:––", valDim: true)
        ]
        for (state, expected) in [(TarasRulerModel.State.noRoute, noRoute), (.checking, checking)] {
            expect(TarasRulerModel.placeholderRows(state: state, limits: limits, calendar: calendar) == expected,
                   "pre-batch rows for \(state) need no invented estimates or suggestion")
            expect(model.rows(at: -1, now: now, state: state) == expected, "instance delegates pre-batch rows for \(state)")
            expect(TarasRulerModel.placeholderRows(state: state, limits: zeroLimits, calendar: calendar)[1] ==
                   Row(label: "NO WRAP-UP TIME SET", status: "NOT NEEDED", glyph: .flat, name: "Wrap up", value: "—", valDim: true),
                   "pre-batch zero packing for \(state)")
        }
        expect(TarasRulerModel.placeholderRows(state: .suggested, limits: limits).isEmpty, "placeholder API cannot invent a suggestion")
        let noFitBatch = TrafficBatch(routeID: "no-fit", checkedAt: time(17, 23), samples: [
            DepartureEstimate(departure: time(17, 35), driving: 1800),
            DepartureEstimate(departure: time(17, 40), driving: 1860)
        ])
        let noFitLimits = WatchLimits(earliest: time(17, 35), latest: time(17, 40), homeBy: time(18, 0), packing: 600)
        let noFit = TarasRulerModel(batch: noFitBatch, limits: noFitLimits, suggestedDeparture: time(17, 35), calendar: calendar)!
        expect(noFit.rows(at: 0, now: time(17, 23), state: .noFit) == [
            Row(label: "BEST CHECKED ARRIVAL", status: "WAIT 12M", glyph: .hour, name: "Leave", value: "17:35", anchor: true),
            Row(label: "−10M · WRAP-UP TIME", status: "IN 2M", glyph: .ringO, name: "Wrap up", value: "17:25"),
            Row(label: "APPLE MAPS", status: "SHORTEST", glyph: .flat, name: "Drive", value: "30 min"),
            Row(label: "ARRIVE BY 18:00", status: "LATE 5M", glyph: .red, name: "Arrive around", value: "18:05")
        ], "state 7 exact rows stay bright and name the cost")
        expect(noFit.rows(at: 1, now: time(17, 23), state: .noFit) == noFit.rows(at: 1, now: time(17, 23)),
               "scrubbed recovery alternatives do not inherit best-arrival/shortest labels or special brightness")
        let fasterArrivalBatch = TrafficBatch(routeID: "earliest-not-shortest", checkedAt: time(17, 23), samples: [
            DepartureEstimate(departure: time(17, 35), driving: 1860),
            DepartureEstimate(departure: time(17, 40), driving: 1800)
        ])
        let recoveryPrimary = DeparturePolicy.earliestArrival(fasterArrivalBatch.samples)!
        let fasterArrival = TarasRulerModel(batch: fasterArrivalBatch, limits: noFitLimits,
                                          suggestedDeparture: recoveryPrimary.departure, calendar: calendar)!
        let recoveryRows = fasterArrival.rows(at: 0, now: time(17, 23), state: .noFit)
        expect(recoveryRows[0].label == "BEST CHECKED ARRIVAL" && recoveryRows[2].status == "LONGEST DRIVE" &&
               recoveryRows[3].value == "18:06" && recoveryRows.allSatisfy { !$0.valDim },
               "best checked arrival need not be the shortest drive")

        for preview in [model, zero] {
            for state in [TarasRulerModel.State.suggested, .watching] {
                for (date, status) in [(time(17, 30), "NOW"), (time(17, 30).addingTimeInterval(1), "NOW"), (time(17, 31), "PASSED")] {
                    let rows = preview.rows(at: 4, now: date, state: state)
                    let expected = state == .watching ? "PREVIEW" : status
                    expect(rows[0].status == expected && !rows[0].go && rows[0].glyph != .green,
                           "uncommitted \(state) never issues a departure cue at \(date)")
                }
            }
        }
        for index in [0, 5, 6] {
            for date in [samples[index].departure, samples[index].departure.addingTimeInterval(60)] {
                var expected = model.rows(at: index, now: date)
                expected[0].status = "PREVIEW"; expected[0].glyph = .none
                expected[1].status = "PREVIEW"; expected[1].glyph = .none
                expect(model.rows(at: index, now: date, state: .watching, committedDeparture: suggested.departure) == expected,
                       "scrubbing sample \(index) preserves its checked readings and uses preview cues")
            }
        }
        let otherCommitment = model.rows(at: 5, now: time(17, 35), state: .watching, committedDeparture: time(17, 35))
        expect(otherCommitment[0].go && otherCommitment[0].glyph == .green, "actual commitment can differ from suggestion")
        expect(!model.rows(at: 4, now: time(17, 30), state: .suggested, committedDeparture: time(17, 30))[0].go,
               "a commitment input alone cannot turn a suggestion green")
        expect(model.bars(state: .noRoute).isEmpty, "no-route ruler has no traffic bars")
        expect(model.bars().map(\.opacity) == [1, 1, 1, 1, 1, 1, 0.35], "normal bar opacity preserves infeasibility")
        for state in [TarasRulerModel.State.paused, .stale] {
            expect(model.bars(state: state).allSatisfy { $0.opacity == 0.3 && $0.dim }, "\(state) dims every bar to 30 percent")
        }
        expect(model.bars(state: .watching, now: time(17, 31), committedDeparture: time(17, 30)).allSatisfy { $0.opacity == 0.3 },
               "missed commitment dims all bars")
        expect(model.bars(state: .watching, now: time(17, 30).addingTimeInterval(59), committedDeparture: time(17, 30)) == model.bars(),
               "bars honor one-minute grace")
        expect(model.bars(state: .watching, now: time(17, 31)) == model.bars(), "no hypothetical missed bars without a commitment")
        expect(model.bars(state: .watching, now: time(17, 31), committedDeparture: time(17, 35)) == model.bars(),
               "bars use actual commitment rather than suggestion")
        expect(noFit.bars(state: .noFit).allSatisfy { $0.opacity == 0.35 }, "no-fit bars remain infeasible at 35 percent")
        checks += TarasPanelFadeTests.run()
        checks += TarasMotionTests.run()
        scrubInteractions(model)
        panelSnapshots()
        calendarEdges()
        print("PASS: \(checks) Taras ruler model assertions.")
    }

    static func scrubInteractions(_ model: TarasRulerModel) {
        var scrub = TarasScrubState()
        expect(scrub.offset == 0 && !scrub.isPreviewing, "scrub starts at suggestion")
        scrub.send(.press(x: 180, y: 0), model: model)
        expect(scrub.send(.drag(2.99), model: model) == .none && scrub.offset == 0, "travel below 3pt stays a click")
        expect(scrub.send(.drag(3), model: model) == .direct && scrub.offset == 3, "3pt begins drag without subtracting slop")
        scrub.send(.drag(1), model: model)
        expect(scrub.offset == 1, "crossing back inside slop continues 1:1")
        scrub.send(.drag(-16), model: model)
        expect(scrub.selectedIndex(in: model) == 5 && model.rows(at: scrub.selectedIndex(in: model), now: model.batch.checkedAt)[0].value == "17:35",
               "snap selects nearest real sample, never a blended time")
        expect(scrub.send(.release, model: model) == .park && scrub.parkedIndex == 5 && scrub.offset == -30 && scrub.isPreviewing, "drag release glides to nearest real sample")
        scrub.send(.home, model: model)
        scrub.send(.press(x: 210, y: 70), model: model)
        expect(scrub.send(.release, model: model) == .park && scrub.parkedIndex == 5 && scrub.offset == -30, "click bar parks")
        scrub.send(.press(x: 90, y: 0), model: model)
        scrub.send(.drag(6), model: model)
        expect(scrub.offset == -24 && scrub.parkedIndex == nil, "drag starts at parked offset")
        scrub.send(.cancel, model: model)
        expect(scrub.offset == 0 && !scrub.isDragging, "cancel returns home")
        scrub.send(.step(-1), model: model)
        expect(scrub.parkedIndex == 3 && scrub.offset == 30, "Left parks previous sample")
        scrub.send(.step(1), model: model)
        expect(scrub.parkedIndex == 4 && scrub.isPreviewing, "Right parks suggestion with scope enabled")
        expect(scrub.send(.use, model: model) == .use(4), "Return uses fitting sample")
        scrub.send(.park(6), model: model)
        expect(scrub.send(.use, model: model) == .none, "Return cannot use a sample that does not fit")
        scrub.send(.step(1), model: model)
        expect(scrub.parkedIndex == 6, "keys clamp at last sample")
        scrub.send(.park(0), model: model)
        scrub.send(.step(-1), model: model)
        expect(scrub.parkedIndex == 0, "keys clamp at first sample")
        expect(scrub.send(.park(-1), model: model) == .none && scrub.parkedIndex == 0, "invalid park leaves state intact")
        scrub.send(.home, model: model)
        scrub.send(.press(x: 10, y: 0), model: model)
        scrub.send(.drag(-70), model: model)
        expect(scrub.offset == -63.5, "rubber beyond last sample has 0.35 resistance")
        scrub.send(.drag(-10000), model: model)
        expect(scrub.offset == -84, "last rubber caps at 24pt")
        scrub.send(.drag(10000), model: model)
        expect(scrub.offset == 144, "first rubber caps at 24pt")
        let previous = scrub
        expect(scrub.send(.drag(.nan), model: model) == .none && scrub == previous, "nonfinite pointer travel is ignored")
        scrub.send(.release, model: model)
        expect(scrub.parkedIndex == 0 && scrub.offset == 120, "rubber-band release parks at first sample")
        scrub.send(.home, model: model)
        expect(scrub == TarasScrubState(), "scope, Esc and closing reset every interaction field")
        scrub.send(.press(x: 12, y: 12), model: model)
        expect(scrub.send(.release, model: model) == .none && !scrub.isPreviewing, "click away from a bar does not park")
        scrub.send(.press(x: 180, y: 0, presentedOffset: -18), model: model)
        scrub.send(.drag(3), model: model)
        expect(scrub.offset == -15, "interrupting a spring starts from the visible offset")
        scrub.send(.home, model: model)
        expect(scrub.accessibilityValue(in: model, now: model.batch.checkedAt) ==
               "Departure 17:30, suggested. 31 minutes driving, arrive around 18:01.", "VoiceOver value matches section 3")
        scrub.send(.step(1), model: model)
        expect(scrub.accessibilityValue(in: model, now: model.batch.checkedAt).hasPrefix("Departure 17:35. 30 minutes driving"), "VoiceOver adjusts actual samples")
    }

    static func panelSnapshots() {
        let fixtures = TarasPanelFixtures.all
        expect(fixtures.count == 11 && Set(fixtures.map(\.name)).count == 11, "all named states have distinct fixtures")
        let expected = [
            ("no-journey", "SETUP", "", "SET ROUTE"),
            ("checking-5-of-7", "CHECKING 5/7", " Checking", "CHECKING"),
            ("suggested", "SUGGESTED · NOT WATCHING", " Check plan", "WATCH 17:30"),
            ("watching-waiting", "WATCHING", " Leave 17:30 · 31m", "I'M LEAVING"),
            ("wrap-up-now", "WATCHING", " Wrap up", "I'M LEAVING"),
            ("leave-now", "WATCHING", " Leave now", "I'M LEAVING"),
            ("paused", "PAUSED", " Paused", "CHECK AGAIN"),
            ("stale", "CHECK EXPIRED", " Paused", "CHECK AGAIN"),
            ("missed", "CHECK PLAN", " Check plan", "CHECK AGAIN"),
            ("no-departure-fits", "NO DEPARTURE FITS", " Check plan", "REVIEW 17:35 · LATE 5M"),
            ("no-wrap-up", "WATCHING", " Leave 17:30 · 31m", "I'M LEAVING")
        ]
        for ((name, snapshot), (expectedName, header, title, capsule)) in zip(fixtures, expected) {
            expect(name == expectedName && snapshot.headerRight == header && snapshot.menuTitle == title && snapshot.capsule == capsule,
                   "header, menuTitle and capsule agree for \(name)")
            expect(snapshot.rows.map(\.name) == ["Leave", "Wrap up", "Drive", "Arrive around"], "four journey rows for \(name)")
            expect(snapshot.ticks.count > 0 && zip(snapshot.ticks, snapshot.ticks.dropFirst()).allSatisfy { abs($1.x - $0.x - 6) < 0.001 },
                   "six-point ticks for \(name)")
        }
        let ready = TarasRulerModel.PanelSnapshot(state: .noRoute, limits: fixtures[0].snapshot.limits,
            now: fixtures[0].snapshot.now, calendar: fixtures[0].snapshot.calendar,
            routeTitle: "North Campus → Harbor Terminal", readyForToday: true)
        expect(ready.rows.map(\.value) == ["—", "10 min", "—", "—"], "ready shows only the configured wrap-up duration")
        expect(ready.rows[0].label == "WINDOW 17:10–17:40", "ready state Leave row names the saved departure window")
        let undoable = TarasRulerModel.PanelSnapshot(state: .noRoute, limits: fixtures[0].snapshot.limits,
            now: fixtures[0].snapshot.now, calendar: fixtures[0].snapshot.calendar, readyForToday: true,
            feedbackLabel: "EDIT JOURNEY TIMES", undoStopAvailable: true)
        expect(undoable.capsule == "UNDO" && undoable.headerRight == "WATCH STOPPED" && undoable.menuTitle.isEmpty,
               "a just-stopped watch offers Undo ahead of other idle labels")
        let left = TarasRulerModel.PanelSnapshot.headerLeftBounds
        let right = TarasRulerModel.PanelSnapshot.headerRightBounds
        expect(left.lowerBound == 12 && left.upperBound <= 174 && right.lowerBound >= 186 && right.upperBound == 348,
               "header labels leave six points on either side of the orange cursor")
        expect(left.upperBound - left.lowerBound == right.upperBound - right.lowerBound,
               "long route tail ellipsis uses the same constrained width as the right header")
        let empty = fixtures[0].snapshot
        expect(empty.model == nil && empty.bars.isEmpty && empty.ticks.allSatisfy(\.dim), "empty ruler needs no fabricated sample")
        let checking = fixtures[1].snapshot
        expect(checking.bars.count == 5 && checking.capsuleDisabled && checking.rows.allSatisfy(\.valDim), "checking has five bars, disabled capsule, placeholders")
        expect(checking.bars(reduceMotion: true).allSatisfy { $0.height == 20 && $0.opacity == 0.6 }, "Reduce Motion keeps uniform marker heights")
        expect(checking.bars[3].x == 180 && checking.bars[4].opacity == 0.6, "checking centers the window, markers are sixty percent")
        expect(checking.bars[4].height == 10, "checking fixture is halfway through 20pt marker growth")
        expect(!fixtures[3].snapshot.circleDisabled && !fixtures[4].snapshot.circleDisabled, "waiting and wrap-up permit five more minutes")
        let leave = fixtures[5].snapshot
        expect(leave.rows[0].go && leave.capsuleGreen && leave.circleDisabled && leave.rows[1].valDim, "leave-now has green row and capsule, dim done value, disabled plus")
        for index in [6, 7, 8] {
            expect(fixtures[index].snapshot.bars.allSatisfy { $0.opacity == 0.3 } && fixtures[index].snapshot.rows.allSatisfy(\.valDim),
                   "unconfirmed or missed fixture dims all bars and values")
        }
        expect(fixtures[8].snapshot.circleSymbol == nil, "missed plan exposes one recheck action")
        expect(fixtures[9].snapshot.bars.allSatisfy { $0.opacity == 0.35 }, "no-fit bars report core infeasibility")
        expect(fixtures[10].snapshot.rows[1].status == "NOT NEEDED" && fixtures[10].snapshot.rows[1].value == "—", "zero wrap-up fixture")

        let suggestion = fixtures[2].snapshot
        let otherDeparture = suggestion.model!.samples[5].departure
        let other = TarasRulerModel.PanelSnapshot(state: .watching, limits: suggestion.limits,
            now: otherDeparture, calendar: suggestion.calendar, model: suggestion.model, routeTitle: suggestion.routeTitle,
            committedDeparture: otherDeparture)
        expect(other.rows[0].value == "17:35" && other.rows[0].go && other.menuTitle == " Leave now" && other.capsuleGreen,
               "snapshot rows and menu use actual commitment when it differs from suggestion")
        let otherWaiting = TarasRulerModel.PanelSnapshot(state: .watching, limits: suggestion.limits,
            now: suggestion.now, calendar: suggestion.calendar, model: suggestion.model, routeTitle: suggestion.routeTitle,
            committedDeparture: otherDeparture)
        expect(otherWaiting.menuTitle == " Leave 17:35 · 30m" && otherWaiting.rows[2].value == "30 min",
               "waiting title takes drive minutes from the same sample as the Drive row")
        let waitingAlertsOff = TarasRulerModel.PanelSnapshot(state: .watching, limits: suggestion.limits,
            now: suggestion.now, calendar: suggestion.calendar, model: suggestion.model,
            committedDeparture: otherDeparture, alertsOff: true)
        expect(waitingAlertsOff.menuTitle == " Alerts off", "alerts off keeps its own waiting title")
        let unknownDrive = TarasRulerModel.PanelSnapshot(state: .watching, limits: suggestion.limits,
            now: suggestion.now, calendar: suggestion.calendar, committedDeparture: otherDeparture)
        expect(unknownDrive.menuTitle.hasPrefix(" Leave ") && !unknownDrive.menuTitle.contains("·"),
               "no drive time keeps the plain leave title")
        expect(other.scrubModel?.suggestion.departure == otherDeparture &&
               TarasScrubState().accessibilityValue(in: other.scrubModel!, now: other.now).hasPrefix("Departure 17:35, suggested."),
               "idle drawing, selection, Return and VoiceOver share the committed origin")
        expect(!other.canUseSample(suggestion.model!.samples[5]) && !other.canUseSample(suggestion.model!.samples[0]),
               "watching scrub is preview-only, including the committed sample")
        expect(suggestion.canUseSample(suggestion.model!.samples[5]) && !suggestion.canUseSample(suggestion.model!.samples[6]),
               "suggested parked samples enable USE only when fitting")
        expect(!suggestion.canUseSample(suggestion.model!.samples[5], previewedIn: other),
               "watching preview cannot acquire USE after background refresh proposes a departure")
        expect(!empty.canUseSample(suggestion.model!.samples[5], previewedIn: suggestion),
               "stop disables any captured suggestion before ready state resets preview")
        let disallowed = TarasRulerModel.PanelSnapshot(state: .suggested, limits: suggestion.limits, now: suggestion.now,
            model: suggestion.model, acceptableDepartures: [])
        expect(!suggestion.canUseSample(suggestion.model!.samples[5], previewedIn: disallowed),
               "an originally unavailable preview cannot acquire a refreshed offer")
        expect(other.bars[5].x == 180 && other.ticks.contains { $0.date == otherDeparture && $0.x == 180 },
               "watching ruler centers actual commitment")
        let pausedOther = TarasRulerModel.PanelSnapshot(state: .paused, limits: suggestion.limits, now: otherDeparture,
            calendar: suggestion.calendar, model: suggestion.model, committedDeparture: otherDeparture)
        expect(pausedOther.rows[0].value == "17:35" && pausedOther.bars[5].x == 180 && pausedOther.rows.allSatisfy(\.valDim),
               "paused snapshot retains actual commitment")

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        for (buttonX, expectedX) in [(1000.0, 825.0), (1430.0, 1080.0), (0.0, 0.0)] {
            let placement = TarasPanelPlacement.resolve(buttonFrame: CGRect(x: buttonX, y: 875, width: 10, height: 25),
                                                        screenFrame: screen, visibleFrame: visible)
            expect(placement.path == .statusItem && placement.origin == CGPoint(x: expectedX, y: 468),
                   "panel opens under button and clamps at screen edge \(buttonX)")
        }
        let missingWindow = TarasPanelPlacement.resolve(buttonFrame: nil, screenFrame: nil, visibleFrame: visible)
        expect(missingWindow.path == .fallback && missingWindow.origin == CGPoint(x: 1080, y: 468),
               "only missing button window uses visible-frame fallback")
        let unplacedButton = TarasPanelPlacement.resolve(buttonFrame: CGRect(x: 0, y: 0, width: 20, height: 25),
            screenFrame: screen, visibleFrame: visible)
        expect(unplacedButton.path == .fallback && unplacedButton.origin == CGPoint(x: 1080, y: 468),
               "a status item without its menu-bar coordinates cannot put first-run setup below the display")
        let convertedButton = TarasPanelPlacement.resolve(buttonFrame: CGRect(x: 1000, y: 875, width: 10, height: 25),
            screenFrame: nil, visibleFrame: visible)
        expect(convertedButton.path == .statusItem && convertedButton.origin.y == 468,
               "converted window frame anchors panel even when screen metadata is unavailable")
        let secondary = TarasPanelPlacement.resolve(buttonFrame: CGRect(x: -700, y: 500, width: 20, height: 25),
            screenFrame: CGRect(x: -1440, y: -375, width: 1440, height: 900), visibleFrame: CGRect(x: -1440, y: -375, width: 1440, height: 875))
        expect(secondary.path == .statusItem && secondary.origin == CGPoint(x: -870, y: 93), "placement handles secondary screen origins")
    }

    static func calendarEdges() {
        for (zone, year, month, day, startHour, endHour, homeHour, departureHour, expectedArrival, expectedSpare) in [
            ("America/Los_Angeles", 2026, 11, 9, 17, 18, 19, 17, "18:01", "59M SPARE"),
            ("America/Los_Angeles", 2026, 11, 9, 23, 0, 1, 23, "00:01", "59M SPARE"),
            ("America/Los_Angeles", 2026, 3, 8, 0, 4, 5, 1, "03:01", "119M SPARE"),
            ("America/Los_Angeles", 2026, 11, 1, 0, 2, 3, 1, "01:01", "119M SPARE"),
            ("Australia/Lord_Howe", 2026, 10, 4, 1, 4, 5, 1, "02:31", "149M SPARE"),
            ("Australia/Lord_Howe", 2026, 4, 5, 0, 2, 3, 1, "01:31", "89M SPARE")
        ] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            func local(_ hour: Int, _ minute: Int, nextDay: Bool = false) -> Date {
                calendar.date(from: DateComponents(year: year, month: month, day: day + (nextDay ? 1 : 0), hour: hour, minute: minute))!
            }
            let crossesMidnight = startHour == 23
            let earliest = local(startHour, 0)
            let latest = local(endHour, 0, nextDay: crossesMidnight)
            let departure = local(departureHour, 30)
            let now = earliest.addingTimeInterval(-60)
            let limits = WatchLimits(earliest: earliest, latest: latest, homeBy: local(homeHour, 0, nextDay: crossesMidnight), packing: 600)
            let batch = TrafficBatch(routeID: zone, checkedAt: now, samples: [
                DepartureEstimate(departure: earliest, driving: 2460),
                DepartureEstimate(departure: departure, driving: 1880),
                DepartureEstimate(departure: latest, driving: 1800)
            ])
            let model = TarasRulerModel(batch: batch, limits: limits, suggestedDeparture: departure, calendar: calendar)!
            let rows = model.rows(at: 1, now: now)
            let label = "\(zone) \(month)/\(day)"
            expect(rows[0].value == String(format: "%02d:30", departureHour), "\(label) formats local departure")
            expect(rows[1].value == String(format: "%02d:20", departureHour), "\(label) formats local wrap-up")
            expect(rows[2].value == "31 min" && rows[3].value == expectedArrival && rows[3].status == expectedSpare,
                   "\(label) rounds once across clock changes and midnight")
            let ticks = model.ticks(offset: -12)
            expect(!ticks.isEmpty && ticks.contains(where: \.isMajor), "\(label) includes major ticks")
            expect(ticks.allSatisfy { tick in
                let minute = calendar.component(.hour, from: tick.date) * 60 + calendar.component(.minute, from: tick.date)
                return tick.isMajor == (minute % model.majorTickMinutes == 0)
            }, "\(label) major ticks follow local clock rather than elapsed minutes")
            expect(zip(ticks, ticks.dropFirst()).allSatisfy { abs($1.x - $0.x - 6) < 0.001 }, "\(label) keeps tick spacing through clock change")
            expect(model.nearestSampleIndex(offset: model.offset(forSampleAt: 2)!) == 2, "\(label) scrub selects returned sample across day boundary")
            if zone == "Australia/Lord_Howe" {
                expect(model.majorTickMinutes == 60, "\(label) tests hourly major ticks")
                expect(ticks.contains { calendar.component(.hour, from: $0.date) == 3 && calendar.component(.minute, from: $0.date) == 0 && $0.isMajor },
                       "\(label) 03:00 is major after the half-hour shift")
                expect(ticks.contains { calendar.component(.hour, from: $0.date) == 3 && calendar.component(.minute, from: $0.date) == 30 && !$0.isMajor },
                       "\(label) 03:30 is minor after the half-hour shift")
            }
            if crossesMidnight {
                expect(model.x(for: latest) > model.x(for: earliest), "midnight never reverses the ruler")
                let checking = TarasRulerModel.placeholderRows(state: .checking, limits: limits, calendar: calendar)
                expect(checking[0].label == "WINDOW 23:00–00:00" && checking[3].label == "ARRIVE BY 01:00", "checking labels cross midnight locally")
            }
        }
    }
}
