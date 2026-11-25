import AppKit
import SwiftUI
import Combine
import WindowCore

private enum TarasInk {
    static let base = Color(taras: 0x1C1C1E), row = Color(taras: 0x232326)
    static let hairline = Color(taras: 0x2E2E32), label = Color(taras: 0xA1A1A7)
    static let text = Color(taras: 0xF2F2F7), dim = Color(taras: 0x94949A)
    static let orange = Color(taras: 0xF5692B), green = Color(taras: 0x30D158), ring = Color(taras: 0x49494E)
}
private extension Color {
    init(taras hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}
private typealias PanelState<Value> = SwiftUI.State<Value>

/// An explicit presentation time lets ImageRenderer inspect the same ruler used on screen.
struct TarasPanelMotionFrame {
    let scene: TarasRulerScene
    var previous: TarasRulerModel.PanelSnapshot?
    var previousRows: [TarasRulerModel.Row]?
    var previousCapsule: String?
    var elapsed: Double = TarasMotion.maxTravel
    var change: PanelChange = .opened
    var selectedIndex: Int?
    var hoveredIndex: Int?
    var pressed = false
    var focused = false
    var reducedMotion: Bool?
    var hoveredControl: String?
    var focusedControl: String?
}

struct TarasPanelView: View {
    enum Action: Equatable {
        case settings, editJourney, scope, delay, refresh, primary, close
        case useSample(Date)
    }
    private let incomingSnapshot: TarasRulerModel.PanelSnapshot
    private var snapshot: TarasRulerModel.PanelSnapshot { pressedSnapshot ?? incomingSnapshot }
    var action: (Action) -> Void = { _ in }
    var acceptsInput = true
    var change: PanelChange = .opened
    var motionFrame: TarasPanelMotionFrame?
    init(snapshot: TarasRulerModel.PanelSnapshot, action: @escaping (Action) -> Void = { _ in },
         acceptsInput: Bool = true, change: PanelChange = .opened, motionFrame: TarasPanelMotionFrame? = nil) {
        incomingSnapshot = snapshot; self.action = action; self.acceptsInput = acceptsInput
        self.change = change; self.motionFrame = motionFrame
    }
    @PanelState private var pressedSnapshot: TarasRulerModel.PanelSnapshot?
    @PanelState private var oldRows: [TarasRulerModel.Row]?
    @PanelState private var scrub = TarasScrubState()
    @PanelState private var motion = TarasRulerDriver()
    @PanelState private var previous: TarasRulerModel.PanelSnapshot?
    @PanelState private var staged: TarasRulerModel.PanelSnapshot?
    @PanelState private var landing = TarasLandingState()
    @PanelState private var rowsCause = PanelChange.opened
    @PanelState private var capsuleState = TarasCapsuleState()
    @PanelState private var footerDeparture: Date?
    @PanelState private var pendingFooter = false
    @PanelState private var hoveredIndex: Int?
    @PanelState private var keyboardFocus = false
    @PanelState private var pointerInput = false
    @PanelState private var parkHaptic = false
    @PanelState private var limitHaptic = false
    @PanelState private var capturedPrimary: (target: CaptureTarget, perform: () -> Void)?
    @PanelState private var previewReturn: Task<Void, Never>?
    @PanelState private var settleTask: Task<Void, Never>?
    @PanelState private var announcements = TarasAnnouncementState()
    @FocusState private var focus: Focus?
    @AccessibilityFocusState private var accessibilityFocus: Bool
    private enum Focus: Hashable { case ruler, gear, edit, circle, earlier, capsule }
    private enum CaptureTarget: Equatable { case primary, offer(Date) }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { motionFrame?.reducedMotion ?? systemReduceMotion }
    @Environment(\.colorSchemeContrast) private var contrast
    private var labelInk: Color { contrast == .increased ? Color(taras: 0xAEAEB2) : TarasInk.label }
    private var dimInk: Color { contrast == .increased ? Color(taras: 0xAEAEB2) : TarasInk.dim }
    private var hairline: Color { contrast == .increased ? Color(taras: 0x48484C) : TarasInk.hairline }
    private var capturedOldRows: [TarasRulerModel.Row]? { motionFrame?.previousRows ?? motionFrame?.previous?.rows }
    private var capturedOldCapsule: String? { motionFrame?.previousCapsule ?? motionFrame?.previous?.capsule }
    private var effectiveCause: PanelChange { motionFrame?.change ?? rowsCause }
    private var content: TarasRulerModel.PanelSnapshot {
        if let frame = motionFrame, frame.change == .batchSettled, frame.elapsed < TarasMotion.settleDelay, let previous = frame.previous { return previous }
        return landing.content(incoming: snapshot, previous: previous, staged: staged)
    }
    private var model: TarasRulerModel? { snapshot.scrubModel }
    private var canScrub: Bool {
        guard let model, model.samples.count > 1, !snapshot.isChecking else { return false }
        return snapshot.state == .suggested || snapshot.state == .noFit || snapshot.state == .watching && snapshot.capsule != "CHECK AGAIN"
    }
    private var selectedIndex: Int? { motionFrame?.selectedIndex ?? model.map { scrub.selectedIndex(in: $0) } }
    private var preview: Bool { motionFrame?.selectedIndex != nil || scrub.isPreviewing }
    private var rows: [TarasRulerModel.Row] {
        guard preview, snapshot.state != .noRoute, snapshot.state != .checking || snapshot.checkingKeepsEvidence,
              let model, let selectedIndex else { return content.rows }
        return model.rows(at: selectedIndex, now: snapshot.now, state: snapshot.checkingKeepsEvidence ? .stale : snapshot.state,
                          committedDeparture: snapshot.committedDeparture, preparationAlreadyUnderway: snapshot.preparationAlreadyUnderway)
    }
    private var parkedOffer: Date? {
        guard preview, canScrub, !scrub.isDragging, !pendingFooter, let model, let selectedIndex,
              model.samples.indices.contains(selectedIndex) else { return nil }
        let departure = footerDeparture ?? capturedFooterDeparture
        return model.samples[selectedIndex].departure == departure ? departure : nil
    }
    private var capsule: String {
        if preview && canScrub && snapshot.state != .watching && parkedOffer == nil {
            return "COMPARING"
        }
        guard canScrub, snapshot.state != .watching, let departure = parkedOffer,
              let model, let index = model.samples.firstIndex(where: { $0.departure == departure }) else { return content.capsule }
        let row = model.rows(at: index, now: snapshot.now, state: snapshot.state)
        return snapshot.state == .noFit ? "REVIEW \(row[0].value) · \(row[3].status)" : "WATCH \(row[0].value)"
    }
    private var capturedFooterDeparture: Date? {
        guard let frame = motionFrame, let index = frame.selectedIndex, let model,
              model.samples.indices.contains(index) else { return nil }
        let duration = reduceMotion ? TarasMotion.reducedTravel : TarasMotion.glide
        return frame.elapsed >= duration ? model.samples[index].departure : nil
    }
    private var capsuleDisabled: Bool {
        if !canScrub || snapshot.state == .watching { return content.capsuleDisabled }
        if let departure = parkedOffer, let model, let sample = model.samples.first(where: { $0.departure == departure }) {
            return !snapshot.canUseSample(sample)
        }
        return preview || content.capsuleDisabled
    }
    private var headerText: String {
        if content.state == .checking, snapshot.state != .checking {
            return "CHECKING \(content.expectedCount)/\(content.expectedCount)"
        }
        // Hovering or scrubbing reads as an offset from the suggestion, as in the approved design.
        if let index = motionFrame?.hoveredIndex ?? hoveredIndex, canScrub, !scrub.isDragging, let model,
           let offset = model.offset(forSampleAt: index) { return model.headerText(offset: offset, parked: true) }
        guard preview, canScrub, let model, let selectedIndex,
              let offset = model.offset(forSampleAt: selectedIndex) else { return content.headerRight }
        return model.headerText(offset: offset, parked: true)
    }
    private var revision: Revision { Revision(snapshot) }
    private struct Revision: Equatable {
        let now: Date, state: TarasRulerModel.State, limits: WatchLimits, route: String
        let samples: [DepartureEstimate], progress: [DepartureEstimate], count: Int
        let checked: Date?, commitment: Date?, header: String, capsule: String, disabled: Bool
        let acceptable: Set<Date>?, circleDisabled: Bool
        init(_ s: TarasRulerModel.PanelSnapshot) {
            now = s.now; state = s.state; limits = s.limits; route = s.routeTitle
            samples = s.model?.samples ?? []; progress = s.checkingSamples; count = s.receivedCount
            checked = s.model?.batch.checkedAt; commitment = s.committedDeparture
            header = s.headerRight; capsule = s.capsule; disabled = s.capsuleDisabled
            acceptable = s.acceptableDepartures; circleDisabled = s.circleDisabled
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in panelRow(row, index: index) }
            footer
        }
        .frame(width: 360, height: 401)
        .background(TarasInk.base)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .circular))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .circular).strokeBorder(.white.opacity(0.09), lineWidth: 1).allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window panel")
        .onAppear {
            motion.scene = TarasRulerScene(snapshot: snapshot); previous = snapshot
            capsuleState.update(capsule, at: ProcessInfo.processInfo.systemUptime, opened: true)
            if acceptsInput { focus = .ruler; accessibilityFocus = true }
        }
        .onChange(of: revision) { _, _ in receiveSnapshot() }
        .onChange(of: capsule) { _, label in capsuleState.update(label, at: ProcessInfo.processInfo.systemUptime) }
        .onDisappear { previewReturn?.cancel(); settleTask?.cancel() }
        .onKeyPress(.tab) { keyboardFocus = true; return .ignored }
        .onKeyPress(.space) { keyboardFocus = true; return .ignored }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in keyboardFocus = false })
        .onExitCommand { escape() }
        .onKeyPress(.return) {
            if focus == .gear || focus == .edit || focus == .circle || focus == .earlier { return .ignored }
            guard TarasCapsuleState.returnMayActivate(capsule), !capsuleDisabled else { return .handled }
            activatePrimary(); return .handled
        }
    }

    private func receiveSnapshot() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let old = previous else { previous = snapshot; motion.scene = TarasRulerScene(snapshot: snapshot); return }
        let cause = PanelChange.classify(previous: old, next: snapshot)
        announcements.receive(cause)
        let holdingLanding = landing.receive(cause)
        if !holdingLanding {
            rowsCause = cause
            if scrub.isPreviewing, let oldModel = old.scrubModel {
                oldRows = oldModel.rows(at: scrub.selectedIndex(in: oldModel), now: old.now, state: old.state,
                                    committedDeparture: old.committedDeparture, preparationAlreadyUnderway: old.preparationAlreadyUnderway)
            } else { oldRows = old.rows }
        }
        var nextScene = motion.scene ?? TarasRulerScene(snapshot: old)
        nextScene.advance(to: now)
        if old.limits != snapshot.limits || old.routeTitle != snapshot.routeTitle {
            scrub = TarasScrubState(); footerDeparture = nil; hoveredIndex = nil
            nextScene = TarasRulerScene(snapshot: snapshot)
        } else if scrub.isPreviewing || scrub.isDragging, let oldModel = old.scrubModel, let newModel = model {
            let departed = scrub.rebase(from: oldModel, to: newModel)
            if departed {
                nextScene.ruler.retarget(newModel.samples[scrub.selectedIndex(in: newModel)].departure.timeIntervalSinceReferenceDate / 60,
                                         at: now, response: TarasMotion.glide, reduced: reduceMotion)
            }
            if footerDeparture != nil { footerDeparture = newModel.samples[scrub.selectedIndex(in: newModel)].departure }
        }
        if cause == .commit {
            scrub = TarasScrubState(); footerDeparture = nil
        }
        if snapshot.state == .paused || snapshot.state == .stale || snapshot.state == .checking {
            if snapshot.committedDeparture != nil {
                scrub = TarasScrubState(); previewReturn?.cancel(); pendingFooter = false; parkHaptic = false
            } else { scrub.clearParkKeepingPosition() }
            footerDeparture = nil; hoveredIndex = nil
        }
        if snapshot.state == .noRoute {
            scrub = TarasScrubState(); footerDeparture = nil; previewReturn?.cancel()
        }
        nextScene.receive(snapshot, change: cause, at: now, previewing: scrub.isPreviewing || scrub.isDragging, reduced: reduceMotion)
        motion.scene = nextScene
        if cause == .batchSettled && scrub.isPreviewing {
            pendingFooter = true
            if !nextScene.ruler.isMoving { landFooter() }
        }
        if cause == .batchSettled && !holdingLanding {
            settleTask?.cancel()
            staged = old
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(TarasMotion.settleDelay))
                guard !Task.isCancelled else { return }
                landing.finish()
                staged = nil
                announce(cause, previous: old)
            }
        } else if holdingLanding {
            // A clock tick cannot cancel the pending landing or its announcement.
        } else { settleTask?.cancel(); staged = nil; announce(cause, previous: old) }
        previous = snapshot
    }

    private func announce(_ cause: PanelChange, previous old: TarasRulerModel.PanelSnapshot) {
        guard acceptsInput else { return }
        let r = snapshot.rows
        guard r.count == 4 else { return }
        let text: String
        switch cause {
        case .batchSettled, .resumed:
            if snapshot.state == .noFit {
                text = "No checked departure fits your limits. Review leaving at \(r[0].value) and arriving around \(r[3].value)."
            } else if old.checkingKeepsEvidence { text = "Checked again. Leave at \(r[0].value)." }
            else { text = "Suggested: leave \(r[0].value). \(r[2].value.replacingOccurrences(of: " min", with: " minutes")) driving, arrive around \(r[3].value)." }
        case .commit: text = "Watching. Leave at \(r[0].value). Wrap up at \(r[1].value)."
        case .delayLanded: text = "Departure moved to \(r[0].value). Wrap up at \(r[1].value)."
        case .phase:
            text = r[0].status == "LEAVE NOW" ? "Leave now." : r[0].status == "PASSED" ? "Departure time passed. Check again for a new time." : "Wrap up now. Leave at \(r[0].value)."
        case .paused: text = snapshot.headerRight.replacingOccurrences(of: " · ", with: ". ") + ". Times are unconfirmed."
        case .ended: text = snapshot.endAnnouncement ?? "Stopped watching."
        case .batchRefreshed where snapshot.state == .suggested && old.state == .watching:
            text = "Traffic changed. Suggested: leave \(r[0].value)."
        case .feedback where snapshot.feedbackLabel == "+5M DOESN'T FIT":
            text = "That departure does not fit. Your previous plan is unchanged."
        default: return
        }
        guard announcements.accepts(text) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func escape() {
        if scrub.escapeReturnsHome(canScrub: canScrub) { send(.home) } else { action(.close) }
    }
    private func activatePrimary() {
        guard !scrub.isDragging, !pendingFooter, !capsuleDisabled, capsuleState.accepts(at: ProcessInfo.processInfo.systemUptime) else { return }
        if performCaptured(.primary) { return }
        if let departure = parkedOffer, snapshot.state != .watching { action(.useSample(departure)) }
        else { action(.primary) }
    }
    private func capturePrimary() {
        if let departure = parkedOffer, canScrub, snapshot.state != .watching { capture(.useSample(departure), target: .primary) }
        else { capture(.primary, target: .primary) }
    }
    private func capture(_ buttonAction: Action, target: CaptureTarget) {
        pressedSnapshot = snapshot
        capturedPrimary = (target, { [action] in action(buttonAction) })
    }
    private func performCaptured(_ target: CaptureTarget) -> Bool {
        guard let capturedPrimary, capturedPrimary.target == target else { return false }
        self.capturedPrimary = nil
        capturedPrimary.perform()
        return true
    }
    private func releaseCapturedAction() {
        Task { @MainActor in
            await Task.yield()
            pressedSnapshot = nil; capturedPrimary = nil
        }
    }
    private func send(_ event: TarasScrubState.Event) {
        if case .escape = event { escape(); return }
        if case .use = event {
            if TarasCapsuleState.returnMayActivate(capsule) { activatePrimary() }; return
        }
        guard canScrub, let model else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var nextScene = motion.scene ?? TarasRulerScene(snapshot: snapshot)
        nextScene.advance(to: now)
        oldRows = rows
        let before = scrub.selectedIndex(in: model)
        var input = event
        if case let .press(x, y, _) = event {
            previewReturn?.cancel(); pointerInput = true; parkHaptic = false; limitHaptic = false; hoveredIndex = nil
            let offset = (model.suggestion.departure.timeIntervalSinceReferenceDate / 60 - nextScene.ruler.position) * model.pointsPerMinute
            nextScene.ruler.jump(to: nextScene.ruler.position)
            input = .press(x: x, y: y, presentedOffset: offset)
        }
        if snapshot.state == .watching {
            switch event { case .release, .releaseProjected: input = .home; default: break }
        }
        if case let .releaseProjected(velocity) = event {
            nextScene.ruler.setVelocity(-velocity / model.pointsPerMinute)
        }
        let effect = scrub.send(input, model: model)
        let target = model.suggestion.departure.timeIntervalSinceReferenceDate / 60 - scrub.offset / model.pointsPerMinute
        switch effect {
        case .direct:
            rowsCause = .scrubStep; nextScene.ruler.jump(to: target)
            if pointerInput && before != scrub.selectedIndex(in: model) { haptic(.alignment) }
            let offsets = model.samples.indices.compactMap { model.offset(forSampleAt: $0) }
            if !limitHaptic, scrub.offset < offsets.min()! || scrub.offset > offsets.max()! {
                limitHaptic = true; if pointerInput { haptic(.levelChange) }
            }
        case .park:
            rowsCause = .park; pendingFooter = true
            nextScene.ruler.retarget(target, at: now, response: TarasMotion.glide, reduced: reduceMotion)
            parkHaptic = pointerInput
        case .home:
            rowsCause = .returnHome; pendingFooter = true; parkHaptic = false; previewReturn?.cancel()
            nextScene.ruler.retarget(target, at: now, response: TarasMotion.home, damping: 1, reduced: reduceMotion)
        default: break
        }
        motion.scene = nextScene
        if !nextScene.ruler.isMoving { landFooter() }
        if snapshot.state == .watching, effect == .park {
            previewReturn?.cancel()
            previewReturn = Task { @MainActor in
                try? await Task.sleep(for: .seconds(TarasMotion.previewHold))
                if !Task.isCancelled { send(.home) }
            }
        }
    }
    private func landFooter() {
        guard pendingFooter else { return }; pendingFooter = false
        if parkHaptic { haptic(.alignment); parkHaptic = false }
        if scrub.isPreviewing, snapshot.state != .watching, let model {
            footerDeparture = model.samples[scrub.selectedIndex(in: model)].departure
        } else { footerDeparture = nil }
    }
    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func mono(_ text: String, lit: Bool = false, intrinsic: Bool = true, truncation: Text.TruncationMode = .tail,
                      from old: String? = nil, duration: Double = TarasMotion.word, delay: Double = 0, animate: Bool = false, numeric: Bool = false) -> some View {
        sampledText(text, from: old, duration: duration, delay: delay, height: 12, numeric: numeric, animate: animate).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.4)
            .foregroundStyle(lit ? TarasInk.text : labelInk).lineLimit(1).truncationMode(truncation)
            .fixedSize(horizontal: intrinsic, vertical: false)
    }
    @ViewBuilder private func sampledText(_ text: String, from old: String?, duration: Double,
                                          delay: Double = 0, height: Double = 20, numeric: Bool = false,
                                          animate: Bool = true) -> some View {
        let travel = numeric && !reduceMotion && old?.contains(where: \.isNumber) != false && text.contains(where: \.isNumber)
        if let frame = motionFrame, let old, old != text {
            let p = TarasMotion.easeOut((frame.elapsed - delay) / duration)
            let opacity = TarasMotion.textOpacities(at: frame.elapsed - delay)
            let direction = numericValue(text) < numericValue(old) ? -1.0 : 1.0
            ZStack(alignment: .trailing) {
                Text(old).opacity(travel ? 1 - p : opacity.old).offset(y: travel ? -direction * p * height : 0)
                Text(text).opacity(travel ? p : opacity.new).offset(y: travel ? direction * (1 - p) * height : 0)
            }.frame(height: height).clipped()
        } else {
            TarasAnimatedText(text: text, numeric: numeric && !reduceMotion, animate: animate)
        }
    }
    private func captureProgress(_ duration: Double, delay: Double = 0) -> Double {
        guard let frame = motionFrame else { return 1 }
        return TarasMotion.easeOut((frame.elapsed - delay) / duration)
    }
    private var captureDelay: Double { effectiveCause == .batchSettled ? TarasMotion.settleDelay : 0 }

    @ViewBuilder private var header: some View {
        if acceptsInput { interactiveHeader }
        else {
            headerContents.frame(height: 85).background(TarasInk.base)
                .overlay { if motionFrame?.focused == true { RoundedRectangle(cornerRadius: 16).stroke(TarasInk.orange, lineWidth: 2).padding(2) } }
        }
    }
    @ViewBuilder private var interactiveHeader: some View {
        let header = headerContents
            .frame(height: 85).background(TarasInk.base)
            .overlay { if acceptsInput { rulerInput } }
            .focusable().focusEffectDisabled().focused($focus, equals: .ruler)
            .onKeyPress(.leftArrow, phases: [.down, .repeat]) { key in keyboardStep(key, right: false) }
            .onKeyPress(.rightArrow, phases: [.down, .repeat]) { key in keyboardStep(key, right: true) }
            .overlay { if focus == .ruler && keyboardFocus || motionFrame?.focused == true { RoundedRectangle(cornerRadius: 16).stroke(TarasInk.orange, lineWidth: 2).padding(2).allowsHitTesting(false) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.routeTitle.isEmpty ? "Departure ruler" : "Departure ruler, \(content.routeTitle)")
            .accessibilityValue(rulerAccessibilityValue)
            .accessibilityHint(canScrub ? "Use the arrow keys to compare checked departures." : "")
            .accessibilityFocused($accessibilityFocus)
        if canScrub {
            header.accessibilityAdjustableAction { direction in
                pointerInput = false
                if direction == .increment { send(.step(1)) }; if direction == .decrement { send(.step(-1)) }
            }
        } else {
            header
        }
    }
    private func keyboardStep(_ key: KeyPress, right: Bool) -> KeyPress.Result {
        guard canScrub else { return .ignored }
        pointerInput = false; keyboardFocus = true
        send(key.modifiers.contains(.option) ? .edge(right) : .step(right ? 1 : -1))
        return .handled
    }
    private var rulerAccessibilityValue: String {
        if snapshot.state == .checking { return "Checking Apple Maps, \(snapshot.receivedCount) of \(snapshot.expectedCount) times checked." }
        if !canScrub { return snapshot.headerRight }
        return model.map { scrub.accessibilityValue(in: $0, now: snapshot.now, committed: snapshot.state == .watching) } ?? snapshot.headerRight
    }
    private var rulerInput: some View {
        TarasRulerInput(send: send, pointer: { pointerInput = $0; keyboardFocus = !$0 }, hover: hoverBar)
            .accessibilityHidden(true)
    }
    private func hoverBar(_ x: Double?, _ y: Double?) {
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard canScrub, !scrub.isDragging, let model, let x, let y else { hoveredIndex = nil; return }
            let center = motion.scene?.ruler.position ?? TarasRulerScene.center(snapshot).timeIntervalSinceReferenceDate / 60
            let offset = (model.suggestion.departure.timeIntervalSinceReferenceDate / 60 - center) * model.pointsPerMinute
            let bars: [TarasRulerModel.SampleBar] = model.bars(offset: offset)
            hoveredIndex = bars.first { bar in
                let nearX = abs(bar.x - x) <= 6.0
                let nearY = y >= 77.0 - bar.height && y <= 85.0
                return nearX && nearY
            }?.index
        }
    }
    private var longRoute: [String] {
        let route = content.headerLeft
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let width = (route as NSString).size(withAttributes: [.font: font, .kern: 0.4]).width
        return width > 162 ? route.components(separatedBy: " → ") : []
    }
    private var headerContents: some View {
        ZStack(alignment: .top) {
            if let frame = motionFrame { rulerDrawing(frame.scene) }
            else { animatedRuler }
            headerLabels
        }
        .help(canScrub ? "\(content.routeTitle)\nDrag to compare departures. Taller bars mean longer drives." : content.routeTitle)
    }
    private var animatedRuler: some View {
        TarasAnimatedRuler(snapshot: snapshot, motion: motion, contrast: contrast,
                           preview: preview, cause: effectiveCause, showCursor: showCursor, landed: landFooter)
    }
    private var headerLabels: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if longRoute.count == 2 {
                    mono(longRoute[0], intrinsic: false, truncation: .middle).frame(width: 162, height: 12, alignment: .leading)
                    mono("→ " + longRoute[1], intrinsic: false, truncation: .middle).frame(width: 162, height: 12, alignment: .leading)
                } else {
                    mono(content.headerLeft, intrinsic: false).frame(width: 162, height: 12, alignment: .leading)
                }
            }.clipped()
            Spacer(minLength: 0)
            mono(headerText, lit: motionFrame?.hoveredIndex == nil && hoveredIndex == nil && (preview || content.headerLit), intrinsic: false,
                 from: effectiveCause == .scrubStep || effectiveCause == .park ? nil : motionFrame?.previous?.headerRight,
                 duration: TarasMotion.roll, delay: captureDelay, animate: headerAnimation != nil,
                 numeric: content.state == .checking)
                .frame(width: 162, alignment: .trailing).clipped()
        }.frame(height: longRoute.count == 2 ? 24 : 12, alignment: .top).padding(.horizontal, 12).offset(y: 12)
    }
    private var headerAnimation: Animation? {
        if effectiveCause == .scrubStep || effectiveCause == .park || hoveredIndex != nil || effectiveCause == .clockTick || effectiveCause == .opened { return nil }
        return content.state == .checking ? TarasMotion.rollAnimation(reduced: reduceMotion) : TarasMotion.uiAnimation
    }
    private func rulerDrawing(_ scene: TarasRulerScene) -> some View {
        let returning = effectiveCause == .returnHome && scene.ruler.isMoving
        let committing = effectiveCause == .commit && scene.band.isMoving
        let showBand = snapshot.state != .noRoute && !(snapshot.state == .checking && !snapshot.checkingKeepsEvidence)
            && (snapshot.state != .watching || preview || returning || committing)
        return TarasRulerDrawing(snapshot: snapshot, scene: scene, contrast: contrast,
                                 showBand: showBand, showCursor: showCursor).accessibilityHidden(true)
    }
    private var showCursor: Bool {
        snapshot.state != .noRoute && (!snapshot.isChecking || snapshot.checkingKeepsEvidence)
    }

    private func panelRow(_ row: TarasRulerModel.Row, index: Int) -> some View {
        let animateWords = !preview && [.phase, .paused, .commit, .batchSettled, .batchRefreshed, .ended, .resumed].contains(effectiveCause)
        return ZStack(alignment: .top) {
            HStack(spacing: 10) {
                mono(row.label)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    mono(row.status, lit: row.go || (row.glyph == .orange && row.status == "WRAP UP NOW") || row.glyph == .red,
                         from: animateWords ? capturedOldRows?[index].status : nil,
                         duration: TarasMotion.word, delay: captureDelay, animate: animateWords)
                    rowGlyph(row, index: index, animate: animateWords)
                }
            }.frame(height: 12).offset(y: 15)
            HStack(spacing: 10) {
                Text(row.name).font(.system(size: 15, weight: .regular)).foregroundStyle(row.nameDim ? dimInk : TarasInk.text)
                Spacer(minLength: 0)
                sampledText(row.value, from: capturedOldRows?[index].value ?? oldRows?[index].value,
                            duration: effectiveCause == .ended ? TarasMotion.ui : capturedOldRows?[index].value.contains("––") == true ? TarasMotion.placeholderFade : TarasMotion.roll,
                            delay: captureDelay, numeric: effectiveCause != .ended,
                            animate: effectiveCause != .opened && effectiveCause != .clockTick)
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    .foregroundStyle(row.valDim || row.dim ? dimInk : TarasInk.text)
                    .animation(preview ? nil : TarasMotion.dimAnimation, value: row.valDim || row.dim)
            }.tracking(-0.1).frame(height: 20).offset(y: 31)
        }
        .padding(.horizontal, 12).frame(height: 64, alignment: .top)
        .background {
            ZStack {
                row.anchor ? TarasInk.base : TarasInk.row
                TarasInk.green.opacity(capturedTint(row, index: index)).animation(preview ? nil : TarasMotion.washAnimation(incoming: row.go), value: row.go)
                if row.glyph == .orange && row.status == "WRAP UP NOW" { TarasInk.orange.opacity(0.07) }
            }
        }
        .overlay(alignment: .top) { hairline.frame(height: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
    }
    private func capturedTint(_ row: TarasRulerModel.Row, index: Int) -> Double {
        guard let old = capturedOldRows?[index], old.go != row.go else { return row.go ? 0.09 : 0 }
        let p = captureProgress(row.go ? TarasMotion.washIn : TarasMotion.washOut)
        let eased = motionFrame.map { TarasMotion.easeInOut($0.elapsed / (row.go ? TarasMotion.washIn : TarasMotion.washOut)) } ?? p
        return 0.09 * (row.go ? eased : 1 - eased)
    }
    @ViewBuilder private func rowGlyph(_ row: TarasRulerModel.Row, index: Int, animate: Bool) -> some View {
        if animate, motionFrame != nil, let old = capturedOldRows?[index].glyph, old != row.glyph {
            let p = captureProgress(reduceMotion ? TarasMotion.reducedFade : TarasMotion.pop, delay: captureDelay)
            ZStack {
                TarasStatusGlyph(glyph: old).opacity(1 - captureProgress(TarasMotion.reducedFade, delay: captureDelay))
                TarasStatusGlyph(glyph: row.glyph).opacity(p)
                    .scaleEffect(!reduceMotion && (row.glyph == .green || row.glyph == .orange) ? 0.6 + 0.4 * p : 1)
            }
        } else {
            TarasAnimatedGlyph(glyph: row.glyph, animate: animate, reduced: reduceMotion,
                               pops: effectiveCause == .phase,
                               fade: effectiveCause == .batchSettled && oldRows?[index].value.contains("––") == true
                                    ? (reduceMotion ? TarasMotion.reducedFade : TarasMotion.placeholderFade) : TarasMotion.word)
        }
    }
    private func numericValue(_ text: String) -> Int { Int(text.filter(\.isNumber)) ?? 0 }

    private func time(_ date: Date) -> String {
        TarasRulerModel.time(date, calendar: snapshot.calendar)
    }

    private var editButton: some View {
        Button { action(.editJourney) } label: {
            Text("EDIT").font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(TarasInk.text).padding(.horizontal, 10).frame(height: 36).contentShape(Capsule())
        }
        .buttonStyle(TarasButtonStyle())
        .accessibilityLabel("Edit journey")
        .focusEffectDisabled().focused($focus, equals: .edit)
        .overlay {
            if focus == .edit && keyboardFocus {
                Capsule().stroke(TarasInk.orange, lineWidth: 2).padding(-3).allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            circle("gearshape", label: "Journey and settings", disabled: false, action: .settings, focus: .gear)
            if content.readyForToday || content.state != .noRoute { editButton }
            Spacer(minLength: 0)
            if let earlier = earlierOffer {
                earlierButton(earlier)
            } else if let symbol = circleSymbol {
                circle(symbol, label: symbol == "scope" ? "Back to suggestion" : symbol == "plus" ? "Five more minutes" : "Check again",
                       disabled: symbol == "scope" ? !preview : content.circleDisabled,
                       action: symbol == "scope" ? .scope : symbol == "plus" ? .delay : .refresh, focus: .circle)
                    .transition(.opacity.animation(TarasMotion.uiAnimation))
            }
            Button(action: activatePrimary) {
                sampledText(capsule, from: capturedOldCapsule, duration: TarasMotion.ui, delay: captureDelay)
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.55)
                    .foregroundStyle(capsuleDisabled ? dimInk : TarasInk.text)
                    .frame(width: capsuleWidth, height: 36).contentShape(Capsule())
            }
            .buttonStyle(TarasButtonStyle(prominent: true, green: content.capsuleGreen, pressed: motionFrame?.pressed == true, greenFraction: capturedGreenFraction, hovered: motionFrame?.hoveredControl == "capsule", onPress: capturePrimary, onRelease: releaseCapturedAction))
            .animation(reduceMotion ? nil : TarasMotion.morphAnimation, value: capsule)
            .disabled(capsuleDisabled).focusEffectDisabled().focused($focus, equals: .capsule)
            .overlay { if focus == .capsule && keyboardFocus || motionFrame?.focusedControl == "capsule" { Capsule().stroke(TarasInk.orange, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
        }
        .animation(reduceMotion ? nil : TarasMotion.morphAnimation, value: capsule)
        .animation(reduceMotion ? nil : TarasMotion.uiAnimation, value: circleSymbol)
        .padding(.horizontal, 12).frame(height: 60).background(TarasInk.row)
        .overlay(alignment: .top) { hairline.frame(height: 1).allowsHitTesting(false) }
    }
    /// The earliest departure that fits, offered beside the suggestion. One press parks the
    /// ruler on it so every row shows that tradeoff; the capsule then watches that time.
    private var earlierOffer: (index: Int, label: String)? {
        guard snapshot.state == .suggested, canScrub, !preview, footerDeparture == nil,
              motionFrame?.selectedIndex == nil, let model, let date = content.earlierDeparture,
              let index = model.samples.firstIndex(where: { $0.departure == date }) else { return nil }
        return (index, time(date))
    }
    private func earlierButton(_ offer: (index: Int, label: String)) -> some View {
        Button { pointerInput = false; send(.park(offer.index)) } label: {
            Text("← \(offer.label)").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.55)
                .foregroundStyle(Color(taras: 0xD1D1D6)).padding(.horizontal, 12)
                .frame(height: 36).contentShape(Capsule())
        }
        .buttonStyle(TarasButtonStyle(hovered: motionFrame?.hoveredControl == "earlier"))
        .help("Compare leaving earlier, at \(offer.label)")
        .accessibilityLabel("Compare leaving earlier, at \(offer.label)")
        .focusEffectDisabled().focused($focus, equals: .earlier)
        .overlay {
            if focus == .earlier && keyboardFocus || motionFrame?.focusedControl == "earlier" {
                Capsule().stroke(TarasInk.orange, lineWidth: 2).padding(-3).allowsHitTesting(false)
            }
        }
        .transition(.opacity.animation(TarasMotion.uiAnimation))
    }
    private var capturedGreenFraction: Double? {
        guard let frame = motionFrame, let old = frame.previous else { return nil }
        guard old.capsuleGreen != content.capsuleGreen else { return content.capsuleGreen ? 1 : 0 }
        let p = TarasMotion.easeInOut(frame.elapsed / (content.capsuleGreen ? TarasMotion.washIn : TarasMotion.washOut))
        return content.capsuleGreen ? p : 1 - p
    }
    private var capsuleWidth: CGFloat {
        let width = measuredCapsule(capsule)
        guard !reduceMotion, let old = capturedOldCapsule else { return width }
        return measuredCapsule(old) + (width - measuredCapsule(old)) * captureProgress(TarasMotion.morph, delay: captureDelay)
    }
    private func measuredCapsule(_ text: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font, .kern: 0.55]).width) + 28
    }
    private var circleSymbol: String? {
        if !canScrub || snapshot.state == .watching { return content.circleSymbol }
        return preview || footerDeparture != nil ? "scope" : content.circleSymbol
    }
    private func circle(_ symbol: String, label: String, disabled: Bool, action buttonAction: Action, focus target: Focus) -> some View {
        Button { if buttonAction == .scope { send(.home) } else { action(buttonAction) } } label: {
            if symbol == "plus" {
                Text("+5 MIN").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(taras: 0xD1D1D6)).padding(.horizontal, 10)
                    .frame(height: 36).contentShape(Capsule())
            } else {
                circleIcon(symbol, focus: target).font(.system(size: 17, weight: .regular)).foregroundStyle(Color(taras: 0xD1D1D6))
                .contentTransition(.opacity).animation(TarasMotion.uiAnimation, value: symbol)
                    .frame(width: 36, height: 36).contentShape(Circle())
            }
        }
        .buttonStyle(TarasButtonStyle(hovered: motionFrame?.hoveredControl == (target == .gear ? "gear" : "circle"))).opacity(capturedCircleOpacity(disabled, focus: target))
        .animation(TarasMotion.uiAnimation, value: disabled).disabled(disabled).help(label).accessibilityLabel(label)
        .focusEffectDisabled().focused($focus, equals: target)
        .overlay { if focus == target && keyboardFocus || motionFrame?.focusedControl == (target == .gear ? "gear" : "circle") { Capsule().stroke(TarasInk.orange, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
    }
    private func capturedCircleOpacity(_ disabled: Bool, focus: Focus) -> Double {
        if focus == .gear { return 1 }
        let target = disabled ? 0.35 : 1.0
        guard let frame = motionFrame, let old = frame.previous else { return target }
        let start = old.circleSymbol == nil ? 0 : old.circleDisabled ? 0.35 : 1.0
        return start + (target - start) * captureProgress(TarasMotion.ui, delay: captureDelay)
    }
    @ViewBuilder private func circleIcon(_ symbol: String, focus: Focus) -> some View {
        if focus == .gear { Image(systemName: symbol) }
        else if let old = motionFrame?.previous?.circleSymbol, old != symbol {
            let p = captureProgress(TarasMotion.ui, delay: captureDelay)
            ZStack { Image(systemName: old).opacity(1 - p); Image(systemName: symbol).opacity(p) }
        } else { Image(systemName: symbol) }
    }

}

private final class TarasRulerDriver: ObservableObject {
    @Published var scene: TarasRulerScene?
}

private struct TarasAnimatedRuler: View {
    let snapshot: TarasRulerModel.PanelSnapshot
    @ObservedObject var motion: TarasRulerDriver
    let contrast: ColorSchemeContrast
    let preview: Bool
    let cause: PanelChange
    let showCursor: Bool
    let landed: () -> Void
    var body: some View {
        let scene = motion.scene ?? TarasRulerScene(snapshot: snapshot)
        let returning = cause == .returnHome && scene.ruler.isMoving
        let committing = cause == .commit && scene.band.isMoving
        let showBand = snapshot.state != .noRoute && !(snapshot.state == .checking && !snapshot.checkingKeepsEvidence)
            && (snapshot.state != .watching || preview || returning || committing)
        TimelineView(.animation(paused: !scene.isMoving)) { timeline in
            TarasRulerDrawing(snapshot: snapshot, scene: scene, contrast: contrast, showBand: showBand, showCursor: showCursor)
                .accessibilityHidden(true)
                .onChange(of: timeline.date) { _, _ in
                    let wasMoving = motion.scene?.ruler.isMoving == true
                    motion.scene?.advance(to: ProcessInfo.processInfo.systemUptime)
                    if wasMoving && motion.scene?.ruler.isMoving != true { landed() }
                }
        }
    }
}

/// Keep one text layer and transition mode through unrelated parent updates.
struct TarasAnimatedText: View {
    let text: String
    let numeric: Bool
    let animate: Bool
    @PanelState private var displayed: String
    @PanelState private var opacity = 1.0
    @PanelState private var rolling = false
    @PanelState private var countsDown = false
    init(text: String, numeric: Bool, animate: Bool) {
        self.text = text; self.numeric = numeric; self.animate = animate
        _displayed = PanelState(initialValue: text)
    }
    var body: some View {
        Text(displayed).contentTransition(rolling ? .numericText(countsDown: countsDown) : .identity).opacity(opacity)
            .task(id: text) {
                guard displayed != text else {
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) { opacity = 1 }
                    return
                }
                guard animate else {
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) { displayed = text; opacity = 1; rolling = false }
                    return
                }
                rolling = numeric && displayed.contains(where: \.isNumber) && text.contains(where: \.isNumber)
                if rolling {
                    countsDown = (Int(text.filter(\.isNumber)) ?? 0) < (Int(displayed.filter(\.isNumber)) ?? 0)
                    withAnimation(TarasMotion.rollAnimation(reduced: false)) { displayed = text; opacity = 1 }
                } else {
                    withAnimation(.easeOut(duration: TarasMotion.textOut)) { opacity = 0 }
                    do { try await Task.sleep(for: .seconds(TarasMotion.textOut)) } catch { return }
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) { displayed = text }
                    withAnimation(.easeOut(duration: TarasMotion.textIn)) { opacity = 1 }
                }
            }
            .accessibilityLabel(text)
    }
}

private struct TarasRulerDrawing: View {
    let snapshot: TarasRulerModel.PanelSnapshot
    let scene: TarasRulerScene
    let contrast: ColorSchemeContrast
    let showBand: Bool
    let showCursor: Bool
    private var pointsPerMinute: Double {
        let minutes = snapshot.limits.latest.timeIntervalSince(snapshot.limits.earliest) / 60
        return 6 / Double([1, 2, 5].first { minutes / Double($0) * 6 <= 300 } ?? 5)
    }
    var body: some View {
        let anchor = snapshot.limits.earliest.addingTimeInterval(snapshot.limits.latest.timeIntervalSince(snapshot.limits.earliest) / 2)
        let shift = (anchor.timeIntervalSinceReferenceDate / 60 - scene.ruler.position) * pointsPerMinute
        let edge = 180 + (scene.band.position - scene.ruler.position) * pointsPerMinute
        let span = min(180, edge), width = showBand ? abs(edge - 180) : 0
        ZStack(alignment: .topLeading) {
            Rectangle().fill(TarasInk.orange.opacity(0.34)).frame(width: width, height: 45).offset(x: span, y: 40)
            ticks(anchor: anchor, orange: false).offset(x: shift - 200)
            ticks(anchor: anchor, orange: true).offset(x: shift - 200)
                .mask(alignment: .topLeading) { Rectangle().frame(width: width, height: 85).offset(x: span) }
            ForEach(scene.retiringBars) { bar in sampleBar(bar) }
            ForEach(scene.bars) { bar in sampleBar(bar) }
            if showCursor { Rectangle().fill(TarasInk.orange).frame(width: 2, height: 31).offset(x: 179) }
        }.frame(width: 360, height: 85, alignment: .topLeading).clipped()
    }
    private func sampleBar(_ bar: TarasBarMotion) -> some View {
        Rectangle().fill(TarasInk.text.opacity(bar.opacity)).frame(width: 2, height: max(0, bar.height))
            .offset(x: 179 + (bar.departure.timeIntervalSinceReferenceDate / 60 - scene.ruler.position) * pointsPerMinute, y: 85 - max(0, bar.height))
    }
    private func ticks(anchor: Date, orange: Bool) -> some View {
        TarasTickStrip(anchor: anchor, limits: snapshot.limits, calendar: snapshot.calendar,
                       allDim: snapshot.state == .noRoute, orange: orange, contrast: contrast, limitDates: [snapshot.limits.earliest, snapshot.limits.latest]).equatable()
    }
}

private struct TarasTickStrip: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.anchor == rhs.anchor && lhs.limitDates == rhs.limitDates && lhs.calendar == rhs.calendar
            && lhs.allDim == rhs.allDim && lhs.orange == rhs.orange && lhs.contrast == rhs.contrast
    }
    let anchor: Date
    let limits: WatchLimits
    let calendar: Calendar
    let allDim: Bool
    let orange: Bool
    let contrast: ColorSchemeContrast
    let limitDates: [Date]
    var body: some View {
        Canvas { context, _ in
            for tick in TarasRulerModel.ticks(center: anchor, limits: limits, calendar: calendar, allDim: allDim, overscan: 200) {
                let ink = orange ? TarasInk.orange : contrast == .increased ? Color(taras: tick.isMajor ? 0xA1A1A7 : 0x85858B) : Color(taras: tick.isMajor ? 0x828288 : 0x68686E)
                let opacity = orange ? (tick.isMajor ? 1.0 : 0.7) : tick.dim ? 0.35 : 1
                context.fill(Path(CGRect(x: tick.x + 199.5, y: 85 - tick.height, width: 1, height: tick.height)), with: .color(ink.opacity(opacity)))
            }
        }.frame(width: 760, height: 85)
    }
}

private struct TarasButtonStyle: ButtonStyle {
    var prominent = false
    var green = false
    var pressed = false
    var greenFraction: Double?
    var hovered = false
    var light = false
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    @Environment(\.isEnabled) private var enabled
    @PanelState private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        let normalRing = enabled && !green ? Color(taras: hover || hovered ? 0x85858B : 0x717178) : TarasInk.ring
        let fillOpacity = enabled ? (light ? (configuration.isPressed ? 0.78 : 1) :
            (configuration.isPressed || pressed ? 0.14 : prominent ? 0.055 : 0)) : 0
        let ring = normalRing.mix(with: TarasInk.green, by: greenFraction ?? (green ? 1 : 0))
        return configuration.label
            .background { shape.fill((green ? TarasInk.green : .white).opacity(fillOpacity))
                    .animation(configuration.isPressed ? nil : TarasMotion.hoverAnimation(incoming: false), value: configuration.isPressed) }
            .overlay { shape.strokeBorder(ring, lineWidth: 1)
                    .animation(TarasMotion.hoverAnimation(incoming: hover), value: hover)
                    .animation(TarasMotion.washAnimation(incoming: green), value: green) }
            .onHover { hover = enabled && $0 }
            .onChange(of: configuration.isPressed) { _, down in if down { onPress() } else { onRelease() } }
    }
}

private struct TarasAnimatedGlyph: View {
    let glyph: TarasRulerModel.Glyph
    let animate: Bool
    let reduced: Bool
    let pops: Bool
    let fade: Double
    private var animation: Animation {
        pops && (glyph == .green || glyph == .orange) ? TarasMotion.popAnimation(reduced: reduced) : .easeInOut(duration: fade)
    }
    @ViewBuilder var body: some View {
        if !animate { TarasStatusGlyph(glyph: glyph) }
        else { ZStack {
            TarasStatusGlyph(glyph: glyph)
                .id(String(describing: glyph))
                .transition(.asymmetric(
                    insertion: (!reduced && pops && (glyph == .green || glyph == .orange) ? AnyTransition.scale(scale: 0.6).combined(with: .opacity) : .opacity)
                        .animation(animation),
                    removal: .opacity.animation(.easeOut(duration: TarasMotion.reducedFade))))
        }.animation(animation, value: glyph) }
    }
}

private struct TarasStatusGlyph: View {
    let glyph: TarasRulerModel.Glyph
    private var size: CGSize {
        switch glyph {
        case .none: return .zero
        case .orange, .green, .red: return CGSize(width: 7, height: 7)
        case .ringO: return CGSize(width: 8, height: 8)
        case .hour: return CGSize(width: 9, height: 11)
        case .check, .checkDim, .warn: return CGSize(width: 10, height: 9)
        case .down: return CGSize(width: 9, height: 10)
        case .pause: return CGSize(width: 8, height: 9)
        case .dots: return CGSize(width: 13, height: 3)
        default: return CGSize(width: 9, height: 9)
        }
    }
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            var color = TarasInk.label
            var width = 1.3
            func line(_ points: [CGPoint]) {
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            switch glyph {
            case .none: break
            case .orange, .green, .red:
                color = glyph == .orange ? TarasInk.orange : glyph == .green ? TarasInk.green : Color(taras: 0xFF453A)
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(color))
            case .ringO:
                color = TarasInk.orange
                path.addEllipse(in: CGRect(x: 0.8, y: 0.8, width: 6.4, height: 6.4))
            case .hour:
                width = 1.2
                line([CGPoint(x: 1, y: 0.8), CGPoint(x: 8, y: 0.8)])
                line([CGPoint(x: 1, y: 10.2), CGPoint(x: 8, y: 10.2)])
                path.move(to: CGPoint(x: 2, y: 0.8))
                path.addCurve(to: CGPoint(x: 7, y: 5.5), control1: CGPoint(x: 2, y: 3.8), control2: CGPoint(x: 7, y: 4))
                path.addCurve(to: CGPoint(x: 2, y: 10.2), control1: CGPoint(x: 7, y: 7), control2: CGPoint(x: 2, y: 7.2))
                path.move(to: CGPoint(x: 7, y: 0.8))
                path.addCurve(to: CGPoint(x: 2, y: 5.5), control1: CGPoint(x: 7, y: 3.8), control2: CGPoint(x: 2, y: 4))
                path.addCurve(to: CGPoint(x: 7, y: 10.2), control1: CGPoint(x: 2, y: 7), control2: CGPoint(x: 7, y: 7.2))
            case .check, .checkDim:
                width = 1.4
                if glyph == .checkDim { color = Color(taras: 0x5A5A60) }
                line([CGPoint(x: 1, y: 4.8), CGPoint(x: 3.8, y: 7.6), CGPoint(x: 9, y: 1.4)])
            case .cross:
                line([CGPoint(x: 1.2, y: 1.2), CGPoint(x: 7.8, y: 7.8)])
                line([CGPoint(x: 7.8, y: 1.2), CGPoint(x: 1.2, y: 7.8)])
            case .down:
                width = 1.4; color = TarasInk.green
                line([CGPoint(x: 4.5, y: 1), CGPoint(x: 4.5, y: 9)])
                line([CGPoint(x: 1.3, y: 5.8), CGPoint(x: 4.5, y: 9), CGPoint(x: 7.7, y: 5.8)])
            case .flat:
                width = 1.4
                line([CGPoint(x: 1, y: 4.5), CGPoint(x: 8, y: 4.5)])
            case .warn:
                width = 1.2; color = Color(taras: 0xFFD60A)
                line([CGPoint(x: 5, y: 0.9), CGPoint(x: 9.3, y: 8.3), CGPoint(x: 0.7, y: 8.3), CGPoint(x: 5, y: 0.9)])
                line([CGPoint(x: 5, y: 3.6), CGPoint(x: 5, y: 5.6)])
            case .pause:
                width = 1.6
                line([CGPoint(x: 2, y: 1), CGPoint(x: 2, y: 8)])
                line([CGPoint(x: 6, y: 1), CGPoint(x: 6, y: 8)])
            case .dots:
                for (index, opacity) in [1.0, 0.6, 0.3].enumerated() {
                    context.fill(Path(ellipseIn: CGRect(x: Double(index) * 5 + 0.2, y: 0.2, width: 2.6, height: 2.6)),
                                 with: .color(color.opacity(opacity)))
                }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
