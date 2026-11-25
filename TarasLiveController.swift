import AppKit
import SwiftUI

// 2026-11-08, GPT-6: disambiguate the State wrapper from the Xcode 27 State macro.
private typealias JourneyEditorState<Value> = SwiftUI.State<Value>
import Combine

@MainActor
public final class TarasLiveController: ObservableObject {
    let watch: LiveWatch
    private let alerts: LocalWatchAlerts
    private var observation: AnyCancellable?
    private var cachedPresentation: TarasLivePresentation!
    private var feedback = TarasFeedbackState()
    private var explicitRecheck = false
    private var updateScheduled = false
    private var windows: [String: NSWindow] = [:]
    public var onOpen: (() -> Void)?

    public init() {
        alerts = LocalWatchAlerts()
        watch = LiveWatch(store: JourneyStore(defaults: .standard), provider: AppleTrafficProvider(), alerts: alerts)
        cachedPresentation = watch.tarasPresentation
        // Published emits before mutation; deliver after the controller finishes its transaction.
        observation = watch.objectWillChange.sink { [weak self] _ in
            guard let self, !self.updateScheduled else { return }
            self.updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updatePresentation()
            }
        }
        alerts.onOpen = { [weak self] in self?.onOpen?() }
    }
    public var presentation: TarasLivePresentation { cachedPresentation }
    private func updatePresentation() {
        let next = watch.tarasPresentation(showChecking: explicitRecheck, previousEvidence: cachedPresentation.snapshot.model)
        let snapshot = next.snapshot.replacingFeedbackLabel(feedback.update(next.snapshot.feedbackLabel, at: watch.now))
        let change = PanelChange.classify(previous: cachedPresentation.snapshot, next: snapshot)
        cachedPresentation = next.replacing(snapshot: snapshot, change: change)
        if !watch.checking { explicitRecheck = false }
        objectWillChange.send()
    }
    public func planSnapshot() throws -> PlanSnapshot { try watch.tarasPlanSnapshot() }
    public var now: Date { watch.now }
    public var active: Bool { watch.active }
    public var requestingAlertPermission: Bool { watch.requestingAlertPermission }
    public var canLeave: Bool { watch.active && watch.plan != nil }
    public func startRuntime() { watch.activateRuntime() }
    public func shutdown() { watch.shutdown() }
    public func becameActive() { watch.updateAuthorization(request: false) }
    public func delay() { watch.delay() }
    public func recheck() {
        explicitRecheck = watch.recheck(replan: watch.needsNewDeparture)
    }
    /// Stops at once; the panel offers Undo for a few seconds (LiveWatch.undoStopSeconds).
    public func stop() { watch.stopWatching() }
    public var canUndoStop: Bool { watch.canUndoStop }
    public func undoStop() { watch.undoStop() }
    public func leave() { watch.finish(title: "You’re on your way", message: "Departure alerts have stopped.") }

    public func primary(_ presentation: TarasLivePresentation) {
        switch presentation.snapshot.state {
        case .noRoute:
            if presentation.snapshot.capsule == "UNDO" { undoStop(); return }
            watch.synchronizeDay()
            if watch.validation == nil { watch.begin() } else { editJourney(setRoute: watch.settings.routeID == nil) }
        case .suggested, .noFit:
            if let offer = presentation.primaryOffer { choose(offer) }
            else { recheck() }
        case .watching:
            if presentation.snapshot.capsule == "CHECK AGAIN" { recheck() } else { leave() }
        case .paused, .stale: recheck()
        case .checking: break
        }
    }
    public func useSample(_ date: Date, from presentation: TarasLivePresentation) {
        guard presentation.snapshot.state == .suggested || presentation.snapshot.state == .noFit,
              let offer = presentation.offers[date] else { return }
        choose(offer)
    }

    private func choose(_ offer: DepartureOffer) {
        guard offer.recovery else { _ = watch.acceptOffer(offer); return }
        guard watch.canAccept(offer) else { _ = watch.acceptOffer(offer); return }
        show("recovery", title: "Review departure", view: TarasRecoveryView(
            rows: TarasRulerModel.recoveryRows(for: offer.choice, original: offer.requestedLimits),
            details: watch.recoveryConsent(offer.choice),
            cancel: { [weak self] in
                self?.windows["recovery"]?.close()
                self?.onOpen?()
            },
            accept: { [weak self] in
                _ = self?.watch.acceptOffer(offer)
                self?.windows["recovery"]?.close()
                self?.onOpen?()
            }))
    }

    public func editJourney(setRoute: Bool = false) {
        if let existing = windows["journey"], existing.isVisible {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        show("journey", title: "Edit journey", view: TarasJourneyEditor(watch: watch, openRoute: setRoute, close: { [weak self] in
            self?.windows["journey"]?.close()
            self?.onOpen?()
        }))
    }
    public func showDetails() {
        show("details", title: "Watch details", view: WatchDetailsView(allowsPermissionRequest: false, onDone: { [weak self] in self?.windows["details"]?.close() }, watch: watch))
    }
    public func showSettings() {
        show("settings", title: "Settings", view: LiveSettingsView(watch: watch))
    }
    private func show<V: View>(_ key: String, title: String, view: V) {
        if let existing = windows[key], existing.isVisible {
            existing.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        let window = windows[key] ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: TarasNativePresentation(watch: watch, content: view))
        // A window takes its title from its content view controller, so name both, and
        // set the window's after the controller is in place ("Settings", "Watch details").
        hosting.title = title
        window.contentViewController = hosting
        window.title = title
        window.setContentSize(hosting.view.fittingSize)
        window.center(); windows[key] = window
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
}

/// Standard window around the existing native editors. All writes still pass
/// through JourneyEdit's day/revision checks.
struct TarasJourneyEditor: View {
    @ObservedObject var watch: LiveWatch
    let openRoute: Bool
    let close: () -> Void
    init(watch: LiveWatch, openRoute: Bool, close: @escaping () -> Void) {
        _watch = ObservedObject(wrappedValue: watch); self.openRoute = openRoute; self.close = close
    }
    private var reading = WindowReadingContext()
    @JourneyEditorState private var edit: JourneyEdit?
    @JourneyEditorState private var route = false
    @JourneyEditorState private var timeField: TimeField?
    @JourneyEditorState private var wrapUp = false
    @JourneyEditorState private var message = ""
    @JourneyEditorState private var saveForFutureDays = false
    private var conflict: Bool { edit.map { $0.day != watch.dayKey || $0.revision != watch.settingsRevision } ?? true }
    private var validationMessage: String? {
        edit.flatMap { watch.draftError($0, saveForFutureDays: saveForFutureDays) }
    }
    private var journey: Binding<SavedJourney> {
        let parentID = edit?.id
        return Binding(get: { edit?.value ?? watch.settings }, set: { value in
            guard !watch.synchronizeDay(), let current = edit,
                  current.acceptsChild(parentID, day: watch.dayKey, revision: watch.settingsRevision) else { return }
            edit?.value = value
        })
    }
    private func minutes(_ field: TimeField) -> Binding<Int> {
        let binding = journey
        return Binding(get: {
            switch field {
            case .earliest: return binding.wrappedValue.earliest
            case .latest: return binding.wrappedValue.latest
            case .homeBy: return binding.wrappedValue.homeBy
            }
        }, set: { value in
            var updated = binding.wrappedValue
            switch field {
            case .earliest: updated.earliest = value
            case .latest: updated.latest = value
            case .homeBy: updated.homeBy = value
            }
            binding.wrappedValue = updated
        })
    }
    /// A place as every other row sets it: a mono kicker (FROM, TO) over the name.
    private func routeLine(_ lead: String, _ name: String, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            WindowKicker(lead)
            Text(name).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// The panel's mono kickers: context for each limit, never its name again.
    /// The two leave times open and close the leaving window; arrive-by carries the spare.
    static func kicker(_ field: TimeField) -> String {
        switch field {
        case .earliest: return "Leaving window opens"
        case .latest: return "Leaving window closes"
        case .homeBy: return "\(Int(WatchLimits.defaultBuffer / 60))m spare planned"
        }
    }
    private var routeName: String {
        journey.wrappedValue.routeID == nil ? "Choose your route" :
            "Edit route. From \(journey.wrappedValue.origin?.name ?? "start") to \(journey.wrappedValue.destination?.name ?? "destination")."
    }
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        VStack(alignment: .leading, spacing: 14) {
            Text("Today’s journey").font(WindowType.font(.title, scale: scale, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            // The panel's rows: a mono caption over the route, then name left, value right.
            VStack(spacing: 0) {
                Button { route = true } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 10 * scale) {
                            if journey.wrappedValue.routeID == nil {
                                routeLine("Route", "Choose your route", scale: scale)
                            } else {
                                // Full names wrap; a place is never cut off mid-word.
                                routeLine("From", journey.wrappedValue.origin?.name ?? "Choose start", scale: scale)
                                routeLine("To", journey.wrappedValue.destination?.name ?? "Choose destination", scale: scale)
                            }
                        }.font(.system(size: Scale.body * scale)).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        TarasEditorChevron(palette: palette, scale: scale)
                    }
                }.buttonStyle(TarasEditorRowButton(palette: palette, first: true))
                    .accessibilityLabel(routeName)
                ForEach(TimeField.allCases) { field in
                    TarasEditorValueRow(kicker: Self.kicker(field), name: field.rawValue,
                                        value: time(minutes(field).wrappedValue)) { timeField = field }
                }
                TarasEditorValueRow(kicker: "Before you drive", name: "Wrap-up time",
                                    value: "\(journey.wrappedValue.packing) min") { wrapUp = true }
            }
            .clipShape(RoundedRectangle(cornerRadius: Palette.radius))
            .overlay(RoundedRectangle(cornerRadius: Palette.radius).stroke(palette.rule))
            .disabled(conflict)
            Text("You get two notifications: one to wrap up, then one to leave.")
                .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if conflict {
                Button("Reload today’s journey") { edit = watch.makeDraft(); saveForFutureDays = false; message = "" }
                    .buttonStyle(TarasCapsuleButton(palette: palette, kind: .secondary))
            }
            if let validationMessage {
                Text(validationMessage).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !message.isEmpty { Text(message).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 6 * scale) {
                WindowCaption("Apply changes to").accessibilityHidden(true)
                TarasScopeChoice(futureDays: $saveForFutureDays, palette: palette, scale: scale).disabled(conflict)
            }
            WindowDialogActions(palette: palette,
                                confirmTitle: saveForFutureDays ? "Save for today and future days" : "Save for today",
                                canConfirm: edit != nil && validationMessage == nil,
                                cancel: close, confirm: {
                guard let edit else { return }
                if let error = watch.applyDraft(edit, saveForFutureDays: saveForFutureDays) { message = error }
                else { close() }
            })
        }.font(WindowType.font(.text, scale: scale)).padding(20)
            // Sized by its content at every text size; nothing scrolls or clips.
            .frame(width: WindowTextMetrics.editorWidth(420, scale: scale), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { edit = watch.makeDraft(); route = openRoute; saveForFutureDays = false }
            .onChange(of: watch.settingsRevision) { _, _ in route = false; timeField = nil; wrapUp = false }
            .onChange(of: watch.dayKey) { _, _ in route = false; timeField = nil; wrapUp = false }
            .sheet(isPresented: $route) { LiveRouteEditor(journey: journey).windowReadingSurface(appearance: "Dark") }
            .sheet(item: $timeField) { field in
                TimeValueEditor(field: field, minutes: minutes(field), day: watch.now).windowReadingSurface(appearance: "Dark")
            }
            .sheet(isPresented: $wrapUp) {
                WrapUpValueEditor(minutes: journey.packing).windowReadingSurface(appearance: "Dark")
            }
    }

}

/// A journey-editor row: name on the left, value on the right in the panel's digits.
private struct TarasEditorValueRow: View {
    let kicker: String
    let name: String
    let value: String
    let action: () -> Void
    var reading = WindowReadingContext()
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        Button(action: action) {
            // A mono kicker over the name; value and chevron sit on the name's line, as in the panel.
            VStack(alignment: .leading, spacing: 4 * scale) {
                WindowKicker(kicker)
                HStack(spacing: 10) {
                    Text(name).font(.system(size: Scale.body * scale))
                    Spacer(minLength: 8)
                    Text(value).font(.system(size: Scale.body * scale, weight: .medium)).monospacedDigit()
                    TarasEditorChevron(palette: palette, scale: scale)
                }
            }
        }.buttonStyle(TarasEditorRowButton(palette: palette))
            .accessibilityLabel("\(name), \(value)").accessibilityHint("Opens an editor.")
    }
}

private struct TarasEditorChevron: View {
    let palette: Palette
    let scale: CGFloat
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 11 * scale, weight: .semibold))
            .foregroundStyle(palette.muted).accessibilityHidden(true)
    }
}

/// Full-row feedback on the panel's row fill, with the panel's hairline between rows.
private struct TarasEditorRowButton: ButtonStyle {
    let palette: Palette
    var first = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, palette: palette, first: first)
    }
    private struct Styled: View {
        let configuration: Configuration
        let palette: Palette
        let first: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.windowTextScale) private var requestedScale
        @JourneyEditorState private var hovering = false
        var body: some View {
            let scale = WindowTextMetrics.normalized(requestedScale)
            configuration.label
                .padding(.horizontal, 12).padding(.vertical, 10 * scale)
                .frame(maxWidth: .infinity, minHeight: 44 * scale, alignment: .leading)
                .background(enabled && (hovering || configuration.isPressed) ? palette.fieldHover : palette.field)
                .overlay(alignment: .top) { if !first { Rectangle().fill(palette.rule).frame(height: 1) } }
                .opacity(enabled ? 1 : Palette.disabled)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, Rectangle())
                .onHover { hovering = enabled && $0 }
                .onChange(of: enabled) { _, value in if !value { hovering = false } }
        }
    }
}

/// Today only / Today and future days, as two halves of one capsule that scale with the text.
private struct TarasScopeChoice: View {
    @Binding var futureDays: Bool
    let palette: Palette
    let scale: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            option("Today only", value: false)
            option("Today and future days", value: true)
        }
        .padding(3)
        .background(TarasCapsuleRing().fill(palette.field))
        .overlay(TarasCapsuleRing().stroke(palette.capsuleRing, lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel("Apply changes to")
    }
    private func option(_ title: String, value: Bool) -> some View {
        let selected = futureDays == value
        return Button { futureDays = value } label: {
            Text(title).font(.system(size: Scale.text * scale, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.ink : palette.muted).lineLimit(1)
                .padding(.horizontal, 12 * scale)
                .frame(maxWidth: .infinity).frame(height: 28 * scale)
                .background(TarasCapsuleRing().fill(selected ? palette.ink.opacity(0.14) : Color.clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The recovery review in the panel's language: the same rows, words and clock.
struct TarasRecoveryView: View {
    let rows: [TarasRulerModel.Row]
    let details: String
    let cancel: () -> Void
    let accept: () -> Void
    var reading = WindowReadingContext()
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        VStack(alignment: .leading, spacing: 14) {
            WindowCaption("No departure fits").accessibilityHidden(true)
            Text("This drive needs more room than your limits")
                .font(WindowType.font(.title, scale: scale, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in TarasWindowRow(row: row, first: index == 0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Palette.radius))
            .overlay(RoundedRectangle(cornerRadius: Palette.radius).stroke(palette.rule))
            Text(details).fixedSize(horizontal: false, vertical: true)
            Text("This applies to this watch only.")
                .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
            WindowDialogActions(palette: palette, confirmTitle: "Accept and watch", cancel: cancel, confirm: accept)
        }
        .font(WindowType.font(.text, scale: scale))
        .padding(20)
        .frame(width: WindowTextMetrics.editorWidth(380, scale: scale), alignment: .leading)
    }
}

/// One panel row for the deeper windows: a mono status line over a name and value.
struct TarasWindowRow: View {
    let row: TarasRulerModel.Row
    var first = false
    var reading = WindowReadingContext()
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 10) {
                Text(row.label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if !row.status.isEmpty {
                    Text(row.status).foregroundStyle(row.glyph == .red ? palette.ink : palette.muted).fixedSize()
                }
                if row.glyph != .none { TarasWindowGlyph(glyph: row.glyph, palette: palette) }
            }
            .font(.system(size: Scale.label * scale, weight: .medium, design: .monospaced)).tracking(0.4 * scale)
            .foregroundStyle(palette.muted)
            HStack(spacing: 10) {
                Text(row.name).font(.system(size: Scale.body * scale))
                Spacer(minLength: 0)
                Text(row.value).font(.system(size: Scale.body * scale, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(row.valDim ? palette.muted : palette.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        // One surface for every row, as in the editor's card; hairlines between rows only.
        .background(palette.field)
        .overlay(alignment: .top) { if !first { Rectangle().fill(palette.rule).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}

/// The panel's check, caution and late marks. Red is for LATE only.
private struct TarasWindowGlyph: View {
    let glyph: TarasRulerModel.Glyph
    let palette: Palette
    var body: some View {
        Canvas { context, size in
            var path = Path()
            switch glyph {
            case .red:
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(palette.error))
            case .check:
                path.move(to: CGPoint(x: 1, y: 4.8))
                path.addLine(to: CGPoint(x: 3.8, y: 7.6))
                path.addLine(to: CGPoint(x: 9, y: 1.4))
                context.stroke(path, with: .color(palette.muted), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            case .warn:
                path.move(to: CGPoint(x: 5, y: 0.9))
                path.addLine(to: CGPoint(x: 9.3, y: 8.3))
                path.addLine(to: CGPoint(x: 0.7, y: 8.3))
                path.closeSubpath()
                path.move(to: CGPoint(x: 5, y: 3.6))
                path.addLine(to: CGPoint(x: 5, y: 5.6))
                context.stroke(path, with: .color(palette.warning), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            default:
                break
            }
        }
        .frame(width: glyph == .red ? 7 : 10, height: glyph == .red ? 7 : 9)
        .accessibilityHidden(true)
    }
}

private struct TarasNativePresentation<Content: View>: View {
    @ObservedObject var watch: LiveWatch
    let content: Content
    @AppStorage("window.textScale") private var textScale = 1.0
    var body: some View {
        content.windowReadingSurface(appearance: "Dark")
            .environment(\.windowTextScale, WindowTextMetrics.normalized(CGFloat(textScale)))
    }
}
