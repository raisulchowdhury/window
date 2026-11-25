import SwiftUI

// 2026-11-08, GPT-6: disambiguate the State wrapper from the Xcode 27 State macro.
private typealias JourneyViewState<Value> = SwiftUI.State<Value>
import AppKit

#if !WINDOW_TARAS_NATIVE
struct LiveWindowView: View {
    @ObservedObject var watch: LiveWatch
    var measuring = false
    var announces = true
    var compact = false
    @JourneyViewState private var panel = false
    @JourneyViewState private var insideWindow = false
    @JourneyViewState private var discoveryEpoch = 0
    @JourneyViewState private var surfaceVisible = true
    @JourneyViewState private var edit: JourneyEdit?
    private enum EditorKind: Equatable { case time(TimeField), wrapUp, route }
    private struct EditorSession: Identifiable {
        let id = UUID()
        let parentID: UUID
        let kind: EditorKind
    }
    private enum ControlFocus: Hashable { case time(TimeField), wrapUp, route, details, comparison, makerMark }
    @JourneyViewState private var editorSession: EditorSession?
    @JourneyViewState private var editorReturnFocus: ControlFocus?
    @FocusState private var focusedControl: ControlFocus?
    @JourneyViewState private var details = false
    @JourneyViewState private var comparison: DepartureOffer?
    @JourneyViewState private var recoveryOffer: DepartureOffer?
    @JourneyViewState private var editMessage = ""
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { watch.settings.appearance == "Dark" || (watch.settings.appearance == "System" && systemScheme == .dark) }
    private var palette: Palette { Palette(dark: dark, highContrast: contrast == .increased) }
    private var isPanel: Bool { compact || panel }
    private var hasPresentedSurface: Bool { editorSession != nil || details || comparison != nil || insideWindow }
    private var canOpenInsideWindow: Bool {
        surfaceVisible && !measuring && CanopyDiscoveryPolicy.canOpenCover(
            watching: watch.active, editing: edit != nil, presenting: hasPresentedSurface,
            busy: watch.checking || watch.testingAlert || watch.requestingAlertPermission)
    }
    private var birdAvailable: Bool {
        !measuring && surfaceVisible && contrast != .increased && CanopyDiscoveryPolicy.canPlay(
            watching: watch.active, busy: watch.checking || watch.testingAlert || watch.requestingAlertPermission,
            needsAttention: watch.plan == nil || watch.wrapUp || watch.stale || watch.risk || watch.missed || watch.alertError != nil,
            choosing: watch.proposal != nil, editing: edit != nil, presenting: hasPresentedSurface)
    }
    private var screen: String { JourneyPresentation.screen(model: watch.screen, editing: edit != nil) }
    private var editHasConflict: Bool { edit.map { $0.day != watch.dayKey || $0.revision != watch.settingsRevision } ?? false }
    private var values: SavedJourney { edit?.value ?? watch.settings }
    private var displayedRoute: SavedJourney { watch.active && screen == "watch" ? watch.route ?? watch.settings : values }
    private var routeLabel: String {
        guard let from = displayedRoute.origin, let to = displayedRoute.destination else { return "Choose your route" }
        return "\(from.name) → \(to.name)"
    }
    private var spokenRoute: String {
        guard let from = displayedRoute.origin, let to = displayedRoute.destination else { return "Choose your route" }
        return "\(from.name) to \(to.name)"
    }
    private var eventToSpeak: String {
        // Presentation changes cannot manufacture a new semantic watch event.
        // The announcement handler separately checks foreground/editor eligibility.
        guard watch.active else { return "" }
        if watch.stale { return watch.pauseReason ?? "Traffic estimates expired. The departure is unconfirmed." }
        if watch.missed { return "Departure time passed. Check a new departure." }
        if let plan = watch.plan {
            return "\(watch.departureCue). Leave at \(liveTime(plan.departure))."
        }
        if let offer = watch.proposal { return "Suggested departure, \(liveTime(offer.choice.departure)). Choose a departure to start watching." }
        return watch.risk ? "Traffic changed. Review your arrival." : ""
    }
    var body: some View {
        Group {
            if measuring { content }
            else { ScrollView { content }.scrollBounceBehavior(.basedOnSize) }
        }
        .frame(minWidth: 420, minHeight: measuring ? 0 : 510)
        .foregroundStyle(palette.ink)
        .background { CanopyBackground(palette: palette, dark: dark, date: watch.now) }
        .background { WindowSurfaceProbe(changed: { panel = $0; surfaceVisible = true }, closed: {
            cancelEditing(); comparison = nil; details = false; insideWindow = false
            surfaceVisible = false; discoveryEpoch += 1
        }) }
        .windowReadingSurface(appearance: watch.settings.appearance, solidBackground: false)
        .sheet(item: editorFor(.route)) { session in
            LiveRouteEditor(journey: childJourneyBinding(session))
                .windowReadingSurface(appearance: watch.settings.appearance)
        }
        .sheet(isPresented: $insideWindow, onDismiss: {
            if surfaceVisible, !watch.active, editorSession == nil { focusedControl = .makerMark }
        }) {
            InsideWindowView().windowReadingSurface(appearance: watch.settings.appearance)
        }
        .onAppear { surfaceVisible = true; captureRecovery() }
        .onChange(of: watch.active) { _, active in
            // An accepted watch on another surface takes priority over this cover.
            if active { insideWindow = false }
        }
        .onChange(of: editorSession?.id) { old, new in
            if old != nil, new == nil, !details, comparison == nil,
               screen == "setup" || screen == "home" { focusedControl = editorReturnFocus }
        }
        .onChange(of: details) { old, new in if old && !new { focusedControl = .details } }
        .onChange(of: comparison?.id) { old, new in if old != nil && new == nil { focusedControl = .comparison } }
        .onChange(of: watch.settingsRevision) { _, revision in
            if let edit, edit.revision != revision { editorSession = nil }
        }
        .onChange(of: watch.risk) { _, risk in if risk { captureRecovery() } }
        .onChange(of: watch.proposal?.id) { _, id in if id != nil { recoveryOffer = nil } }
        .onChange(of: watch.plan?.departure) { _, date in if date != nil { recoveryOffer = nil } }
        .onChange(of: watch.dayKey) { _, _ in
            // Keep the outdated parent for the existing Reload/Cancel choice;
            // its child no longer has authority to write into it.
            editorSession = nil
            comparison = nil; recoveryOffer = nil; details = false; insideWindow = false
            discoveryEpoch += 1
        }
        .onChange(of: watch.screen) { _, screen in
            if screen != "watch" { comparison = nil }
            if screen == "finished" { cancelEditing(); recoveryOffer = nil; details = false }
        }
        // Only the visible foreground main surface announces. Native alerts
        // remain separate; a hidden window must not interrupt an open editor.
        .onChange(of: eventToSpeak) { old, new in
            let mainWindow = (NSApp.delegate as? AppDelegate)?.window
            if announces, NSApp.isActive, mainWindow?.isKeyWindow == true,
               mainWindow?.isVisible == true, !hasPresentedSurface, edit == nil,
               !new.isEmpty, old != new { AccessibilityNotification.Announcement(new).post() }
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if screen == "finished" { finished }
            else if screen == "watch" { watching }
            else { journey }
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    guard canOpenInsideWindow else { return }
                    insideWindow = true
                } label: {
                    VStack(spacing: 3) {
                        ForEach(0..<2) { _ in HStack(spacing: 3) { Circle().frame(width: 7, height: 7); Circle().frame(width: 7, height: 7) } }
                    }.foregroundStyle(palette.accent).frame(width: 24, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).focused($focusedControl, equals: .makerMark)
                    .disabled(!canOpenInsideWindow)
                    .accessibilityLabel("Inside Window")
                    .help(watch.active ? "Inside Window is available between watches." : "Inside Window")
                Text("Window").font(WindowType.font(.display, scale: scale, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                CanopyBirdView(available: birdAvailable).id(discoveryEpoch)
                    .opacity(contrast == .increased ? 0 : 1)
                    .accessibilityHidden(!birdAvailable)
                Button { editorSession = nil; comparison = nil; details = false; NSApp.sendAction(#selector(AppDelegate.showSettings), to: NSApp.delegate, from: nil) } label: {
                    Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 20, height: 24)
                }.buttonStyle(WindowNativeButton(palette: palette, prominent: false, fillsWidth: false)).accessibilityLabel("Settings").help("Settings (⌘,)")
            }
            if screen == "watch" {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(routeLabel).font(WindowType.font(.text, scale: scale)).foregroundStyle(palette.muted)
                        .lineLimit(2).truncationMode(.middle)
                        .accessibilityLabel("\(displayedRoute.origin?.name ?? "Starting place") to \(displayedRoute.destination?.name ?? "Home")")
                    Spacer(minLength: 0)
                    if !isPanel { editJourneyButton }
                }
            }
            statusButton
            if screen == "watch" { rule }
        }
    }
    private var statusButton: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { showDetails() } label: {
                HStack(spacing: 7) {
                    Circle().fill(watch.stale || watch.risk || watch.missed || watch.alertError != nil || watch.alertAuthorization != .allowed ? palette.warning : palette.watching)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(watch.active ? watch.status : "Watch details")
                    Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
                }
            }.buttonStyle(WindowSecondaryButton(palette: palette, size: Scale.caption, color: palette.muted))
                .focused($focusedControl, equals: .details)
                .accessibilityLabel(watch.active ? "\(watch.status). Watch details" : "Watch details and alerts")
                .help("Traffic freshness, today’s limits, and alerts")
                .popover(isPresented: $details) { WatchDetailsView(watch: watch).windowReadingSurface(appearance: watch.settings.appearance) }
            Spacer(minLength: 0)
            if watch.active && (watch.alertAuthorization != .allowed || watch.alertError != nil) {
                Button(watch.alertStatusLabel) { editorSession = nil; comparison = nil; details = true }
                    .buttonStyle(WindowSecondaryButton(palette: palette, size: Scale.caption, color: palette.warning))
                    .accessibilityLabel("Review notification availability")
            }
        }
    }
    private var editJourneyButton: some View {
        Button("Edit today") { comparison = nil; details = false; edit = watch.makeDraft(); editMessage = "" }
            .buttonStyle(WindowSecondaryButton(palette: palette, size: Scale.caption)).fixedSize()
    }
    private var rule: some View { Rectangle().fill(palette.rule).frame(height: 1) }
    private func caption(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(WindowType.font(.caption, scale: scale)).foregroundStyle(warning ? palette.warning : palette.muted).fixedSize(horizontal: false, vertical: true)
    }
    private func showDetails() { editorSession = nil; comparison = nil; details = true }
    private func ensureDraft() { if edit == nil { edit = watch.makeDraft(); editMessage = "" } }
    private func cancelEditing() {
        edit = nil; editorSession = nil; editMessage = ""
    }
    private func openEditor(_ kind: EditorKind) {
        details = false; comparison = nil
        ensureDraft()
        guard !editHasConflict, let edit else { return }
        switch kind {
        case .time(let field): editorReturnFocus = .time(field)
        case .wrapUp: editorReturnFocus = .wrapUp
        case .route: editorReturnFocus = .route
        }
        editorSession = EditorSession(parentID: edit.id, kind: kind)
    }
    private func editorFor(_ kind: EditorKind) -> Binding<EditorSession?> {
        let presentedID = editorSession?.id
        return Binding(get: { editorSession?.kind == kind ? editorSession : nil }, set: { value in
            if value == nil, editorSession?.id == presentedID { editorSession = nil }
        })
    }
    private func childJourneyBinding(_ session: EditorSession) -> Binding<SavedJourney> {
        Binding(get: { values }, set: { value in
            guard !watch.synchronizeDay(), editorSession?.id == session.id,
                  let current = edit,
                  current.acceptsChild(session.parentID, day: watch.dayKey, revision: watch.settingsRevision) else { return }
            edit?.value = value; editMessage = ""
        })
    }
    private func childFieldBinding(_ field: TimeField, session: EditorSession) -> Binding<Int> {
        let journey = childJourneyBinding(session)
        return Binding(get: {
            switch field {
            case .homeBy: return journey.wrappedValue.homeBy
            case .earliest: return max(journey.wrappedValue.earliest, liveMinutes(watch.now))
            case .latest: return journey.wrappedValue.latest
            }
        }, set: { value in
            var updated = journey.wrappedValue
            switch field {
            case .homeBy: updated.homeBy = value
            case .earliest: updated.earliest = value
            case .latest: updated.latest = value
            }
            journey.wrappedValue = updated
        })
    }
    private func childWrapUpBinding(_ session: EditorSession) -> Binding<Int> {
        let journey = childJourneyBinding(session)
        return Binding(get: { journey.wrappedValue.packing }, set: { value in
            var updated = journey.wrappedValue; updated.packing = value; journey.wrappedValue = updated
        })
    }
    private func fieldBinding(_ field: TimeField) -> Binding<Int> {
        Binding(get: {
            switch field {
            case .homeBy: return values.homeBy
            case .earliest: return max(values.earliest, liveMinutes(watch.now))
            case .latest: return values.latest
            }
        }, set: { value in
            ensureDraft()
            guard !editHasConflict else { return }
            editMessage = ""
            switch field {
            case .homeBy: edit?.value.homeBy = value
            case .earliest: edit?.value.earliest = max(value, liveMinutes(watch.now))
            case .latest: edit?.value.latest = value
            }
        })
    }
    private var wrapUpBinding: Binding<Int> {
        Binding(get: { values.packing }, set: { ensureDraft(); if !editHasConflict { edit?.value.packing = $0; editMessage = "" } })
    }
    private func timeRow(_ field: TimeField, prominent: Bool = false) -> some View {
        let binding = fieldBinding(field)
        return HStack {
            Text(field.rawValue).font(WindowType.font(prominent ? .title : .text, scale: scale, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? palette.ink : palette.muted)
            Spacer()
            Button { openEditor(.time(field)) } label: {
                HStack(spacing: 6) {
                    if prominent { DotTime(text: time(binding.wrappedValue), color: palette.accent, height: 28 * scale) }
                    else { Text(time(binding.wrappedValue)).font(WindowType.font(.body, scale: scale, weight: .medium).monospacedDigit()) }
                    if !meridiem(binding.wrappedValue).isEmpty {
                        Text(meridiem(binding.wrappedValue)).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                    }
                }.padding(.horizontal, 12).padding(.vertical, prominent ? 8 : 6)
            }.buttonStyle(WindowFieldButton(palette: palette))
                .focused($focusedControl, equals: .time(field))
                .accessibilityLabel("\(field.rawValue), \(spoken(binding.wrappedValue))")
                .accessibilityAdjustableAction { direction in
                    binding.wrappedValue = TimeScrollAccumulator.adjusted(binding.wrappedValue, steps: direction == .increment ? 1 : -1, bounds: 0...1439)
                }
                .modifier(ScrollAdjustableTime(value: binding, bounds: 0...1439))
                .help("Scroll to adjust by five minutes, or click to enter a time. Changes apply only when you confirm today’s journey.")
                .popover(item: editorFor(.time(field))) { session in
                    TimeValueEditor(field: field, minutes: childFieldBinding(field, session: session), day: watch.now)
                        .windowReadingSurface(appearance: watch.settings.appearance)
                }
        }.padding(.vertical, prominent ? 12 : 8).disabled(editHasConflict)
    }
    private var journey: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { openEditor(.route) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mappin").foregroundStyle(palette.accent).accessibilityHidden(true)
                    Text(routeLabel).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(palette.muted).accessibilityHidden(true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(WindowSecondaryButton(palette: palette, size: Scale.body)).focused($focusedControl, equals: .route).accessibilityLabel("Edit route. \(spokenRoute)")
                .padding(.bottom, 10).disabled(editHasConflict)
            rule
            timeRow(.homeBy, prominent: true); rule
            timeRow(.earliest); rule
            timeRow(.latest); rule
            HStack {
                Text("Wrap-up time").font(WindowType.font(.text, scale: scale)).foregroundStyle(palette.muted)
                Spacer()
                Button { openEditor(.wrapUp) } label: {
                    Text("\(values.packing) min").font(WindowType.font(.body, scale: scale, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }.buttonStyle(WindowFieldButton(palette: palette))
                    .focused($focusedControl, equals: .wrapUp)
                    .accessibilityLabel("Wrap-up time, \(WindowCopy.minutes(values.packing))")
                    .accessibilityAdjustableAction { direction in
                        wrapUpBinding.wrappedValue = TimeScrollAccumulator.adjusted(values.packing, steps: direction == .increment ? 1 : -1, bounds: 0...30)
                    }
                    .modifier(ScrollAdjustableTime(value: wrapUpBinding, bounds: 0...30))
                    .popover(item: editorFor(.wrapUp)) { session in
                        WrapUpValueEditor(minutes: childWrapUpBinding(session)).windowReadingSurface(appearance: watch.settings.appearance)
                    }
                    .help("Time to finish up and reach your car before the drive starts.")
            }.padding(.vertical, 8).disabled(editHasConflict)
            rule
            if !editMessage.isEmpty { caption(editMessage, warning: true).padding(.top, 8) }
            if let edit {
                if let error = watch.draftError(edit) { caption(error, warning: true).padding(.top, 8) }
                if editHasConflict {
                    Button("Reload today’s journey") { self.edit = watch.makeDraft(); editorSession = nil; editMessage = "" }
                        .buttonStyle(WindowSecondaryButton(palette: palette))
                        .help("Discard this outdated draft and load the latest accepted journey.")
                }
                Button("Apply for today") {
                    guard !hasPresentedSurface else { return }
                    if let error = watch.applyDraft(edit) { editMessage = error }
                    else { self.edit = nil; editMessage = "" }
                }.buttonStyle(WindowNativeButton(palette: palette)).disabled(watch.draftError(edit) != nil)
                    .keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction).padding(.top, 14)
                HStack {
                    caption("Your usual times stay unchanged.")
                    Spacer(minLength: 8)
                    Button("Cancel") { cancelEditing() }.buttonStyle(WindowSecondaryButton(palette: palette)).keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.cancelAction)
                }.padding(.top, 6)
            } else if values.routeID == nil {
                Button("Choose your route") { openEditor(.route) }
                    .buttonStyle(WindowNativeButton(palette: palette)).keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction).padding(.top, 14)
            } else if watch.active {
                Button("Return to watch") { watch.screen = "watch" }.buttonStyle(WindowNativeButton(palette: palette))
                    .keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction).padding(.top, 14)
            } else {
                if let error = watch.validation { caption(error, warning: true).padding(.top, 8) }
                Button("Check departure times") { watch.begin() }.buttonStyle(WindowNativeButton(palette: palette))
                    .disabled(watch.validation != nil).keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction).padding(.top, 14)
                if watch.hasTodayTimes {
                    Button("Make these my usual times") { _ = watch.makeUsualTimes() }
                        .buttonStyle(WindowSecondaryButton(palette: palette, size: Scale.caption)).padding(.top, 4)
                }
                if !watch.message.isEmpty { caption(watch.message).padding(.top, 4) }
            }
            footer.padding(.top, 12)
        }
    }
    private var footer: some View {
        caption("Apple Maps · Mac awake and online")
    }
    private func departure(_ choice: DepartureEstimate, suggested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(suggested ? "SUGGESTED DEPARTURE" : "LEAVE AT")
                .font(WindowType.font(.label, scale: scale)).tracking(2 * scale).foregroundStyle(palette.muted)
            HStack(alignment: .bottom, spacing: 6) {
                SettlingDotTime(text: time(liveMinutes(choice.departure)), color: palette.accent, height: 56 * scale)
                if !meridiem(liveMinutes(choice.departure)).isEmpty {
                    Text(meridiem(liveMinutes(choice.departure))).font(WindowType.font(.text, scale: scale)).foregroundStyle(palette.accent).padding(.bottom, 4)
                }
            }
            Text(WindowCopy.travelLine(choice))
                .font(WindowType.font(.text, scale: scale)).foregroundStyle(palette.muted).contentTransition(.opacity)
            if !suggested {
                Text(watch.departureCue).font(WindowType.font(.title, scale: scale, weight: watch.wrapUp ? .semibold : .regular))
                    .foregroundStyle(watch.wrapUp ? palette.accent : palette.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggested ? "Suggested departure" : "Leave at") \(liveTime(choice.departure)). \(suggested ? "" : watch.departureCue + ". ")\(WindowCopy.spokenDriving(choice)). Arrive around \(liveTime(choice.displayArrival)).")
    }
    private func stop() { watch.finish(title: "Watch stopped", message: "Departure alerts have stopped.") }
    private func leave() { watch.finish(title: "You’re on your way", message: "Departure alerts have stopped.") }
    private var watching: some View {
        // A suggestion has a full three-line trade-off plus explicit consent.
        // Keep every action visible at the standard size, including the panel's edit action.
        VStack(alignment: .leading, spacing: watch.proposal != nil && watch.plan == nil ? (isPanel ? 6 : 8) : 12) {
            if watch.checking && watch.batch == nil {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking departure times").font(WindowType.font(.title, scale: scale)) }
                caption("Comparing driving times within today’s limits.")
                Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette))
            } else if watch.stale {
                Text(watch.staleHeading)
                    .font(WindowType.font(.display, scale: scale, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                caption(watch.staleExplanation)
                if let previous = watch.plan ?? watch.proposal?.choice {
                    caption("Last checked: leave \(liveTime(previous.departure)), arrive around \(liveTime(previous.displayArrival)). This is not a current recommendation.")
                }
                Button(watch.checking ? "Checking…" : watch.needsNewDeparture ? "Recheck from now" : "Check again") { watch.recheck(replan: watch.needsNewDeparture) }
                    .buttonStyle(WindowNativeButton(palette: palette)).disabled(watch.checking || !watch.online || watch.sleeping)
                Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette))
            } else if watch.missed {
                Text("Your departure time passed").font(WindowType.font(.display, scale: scale, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                caption("Your limits are unchanged. Check a new departure when you’re ready.")
                Button(watch.checking ? "Checking…" : "Recheck from now") { watch.recheck(replan: true) }.buttonStyle(WindowNativeButton(palette: palette)).disabled(!watch.canRecheck)
                Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette))
            } else if let choice = watch.plan ?? watch.proposal?.choice {
                // Keep the same view identity as a checked suggestion becomes a
                // commitment. Traffic status may change; the time does not jump
                // into a newly constructed clock with a different animation owner.
                departure(choice, suggested: watch.plan == nil)
                if let offer = watch.proposal, watch.plan == nil {
                    if let baseline = offer.baseline, baseline.departure != offer.choice.departure {
                        TradeoffLines(choice: offer.choice, baseline: baseline)
                    } else { caption("Leaving later would not make this drive much shorter.") }
                    if !watch.canAccept(offer) { caption("This departure needs a fresh check before you choose it.") }
                    Button(watch.canAccept(offer) ? "Use \(liveTime(offer.choice.departure))" : "Check again") {
                        if watch.canAccept(offer) { _ = watch.acceptOffer(offer) } else { watch.recheck() }
                    }.buttonStyle(WindowNativeButton(palette: palette)).keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction)
                        .disabled(watch.checking || !watch.online || watch.sleeping)
                    caption(watch.departureAcceptanceNote)
                    Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette, color: palette.muted))
                } else if watch.plan != nil {
                    if let note = watch.arrivalNote { Text(note).font(WindowType.font(.text, scale: scale)) }
                    if let notice = watch.planNotice { caption(notice) }
                    if !isPanel, let text = watch.planComparison { caption(text) }
                    if watch.wrapUp {
                        Button("I’m leaving") { leave() }.buttonStyle(WindowNativeButton(palette: palette)).keyboardShortcut(hasPresentedSurface ? nil : KeyboardShortcut.defaultAction)
                        HStack {
                            Button(watch.pendingDeparture != nil ? "Checking…" : "Five more minutes") { watch.delay() }
                                .buttonStyle(WindowSecondaryButton(palette: palette)).disabled(!watch.canDelay)
                                .help(watch.delayUnavailableReason ?? "Check a departure exactly five minutes later.")
                                .accessibilityHint(watch.delayUnavailableReason ?? "Checks a departure exactly five minutes later")
                            Spacer(minLength: 8)
                            Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette, color: palette.muted))
                        }
                    } else {
                        Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette, color: palette.muted))
                    }
                }
            } else if watch.risk, let offer = recoveryOffer {
                Text("Review your arrival time").font(WindowType.font(.title, scale: scale, weight: .medium))
                DepartureOfferContent(offer: offer)
                if watch.canAccept(offer) {
                    Button(watch.recoveryAction(offer.choice)) { _ = watch.acceptOffer(offer) }
                        .buttonStyle(WindowNativeButton(palette: palette))
                } else {
                    caption(WindowCopy.offerNeedsCheck)
                    Button("Check again") { recoveryOffer = nil; watch.recheck(replan: true) }
                        .buttonStyle(WindowNativeButton(palette: palette)).disabled(watch.checking || !watch.online || watch.sleeping)
                }
                Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette, color: palette.muted))
            } else {
                Text("Check a new departure").font(WindowType.font(.title, scale: scale, weight: .medium))
                caption(watch.message.isEmpty ? "No departure estimate is available yet." : watch.message)
                Button("Check again") { watch.recheck(replan: true) }.buttonStyle(WindowNativeButton(palette: palette))
                    .disabled(watch.checking || !watch.online || watch.sleeping)
                Button("Edit today’s limits") { comparison = nil; details = false; edit = watch.makeDraft() }.buttonStyle(WindowSecondaryButton(palette: palette))
                Button("Stop watching") { stop() }.buttonStyle(WindowSecondaryButton(palette: palette, color: palette.muted))
            }
            comparisonAction
            if isPanel { editJourneyButton }
            footer
        }
    }
    private var comparisonCandidate: DepartureOffer? {
        if let offer = watch.proposal, let baseline = offer.baseline,
           baseline.departure != offer.choice.departure, baseline.departure >= watch.now,
           offer.limits.fits(baseline) { return watch.offer(for: baseline, baseline: offer.choice) }
        if let plan = watch.plan, !watch.wrapUp {
            if let earlier = watch.sooner { return watch.offer(for: earlier, baseline: plan) }
            if let alternative = watch.drivingAlternative { return watch.offer(for: alternative, baseline: plan) }
        }
        if watch.risk, let primary = recoveryOffer, watch.canAccept(primary),
           let alternative = watch.recoveryOptions?.alternative {
            return watch.offer(for: alternative, baseline: primary.choice, recovery: true)
        }
        return nil
    }
    @ViewBuilder private var comparisonAction: some View {
        if let offer = comparison ?? comparisonCandidate {
            let earlier = offer.baseline.map { offer.choice.departure < $0.departure } ?? false
            Button(earlier ? "Compare earlier departure" : "Compare less driving") {
                editorSession = nil; details = false; comparison = offer
            }
            .buttonStyle(WindowSecondaryButton(palette: palette))
            .focused($focusedControl, equals: .comparison)
            .disabled(comparison == nil && watch.checking)
            .popover(item: $comparison) { offer in
                DepartureOfferView(watch: watch, offer: offer).windowReadingSurface(appearance: watch.settings.appearance)
            }
        }
    }
    private func captureRecovery() {
        guard recoveryOffer == nil, watch.risk, let choice = watch.recoveryOptions?.primary else { return }
        recoveryOffer = watch.offer(for: choice, recovery: true)
    }
    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(watch.endTitle).font(WindowType.font(.display, scale: scale, weight: .medium))
            caption(watch.endMessage)
            Button("Today’s journey") { watch.screen = "home" }.buttonStyle(WindowSecondaryButton(palette: palette))
        }.padding(.vertical, 12)
    }
}

#endif

struct TimeValueEditor: View {
    let field: TimeField
    @Binding var minutes: Int
    let day: Date
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    private var palette: Palette { reading.palette }
    @JourneyViewState private var draft = Date()
    @JourneyViewState private var entry: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    init(field: TimeField, minutes: Binding<Int>, day: Date) {
        self.field = field; self._minutes = minutes; self.day = day
        self._draft = JourneyViewState(initialValue: Calendar.current.date(bySettingHour: minutes.wrappedValue / 60,
            minute: minutes.wrappedValue % 60, second: 0, of: day) ?? day)
        // Seeded from the journey's current value, in the app's 24-hour clock.
        self._entry = JourneyViewState(initialValue: MinuteEntry.clockText(minutes.wrappedValue))
    }
    private var value: Int? { MinuteEntry.clock(entry) }
    private var stepperValue: Binding<Int> {
        Binding(get: { value ?? minutes }, set: { entry = MinuteEntry.clockText($0) })
    }
    private var explanation: String {
        switch field {
        case .homeBy: return "Suggested departures get you there at least \(Int(WatchLimits.defaultBuffer / 60)) min before this."
        case .earliest: return "The earliest you can start driving, after wrapping up and reaching your car."
        case .latest: return "The latest you want to start driving. Anything later needs your OK first."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(field.rawValue).font(WindowType.font(.title, scale: scale, weight: .semibold)).accessibilityAddTraits(.isHeader)
            #if WINDOW_TARAS_NATIVE
            // The shipped app keeps one clock: type a 24-hour time, or step by five minutes
            // with the arrows built into the field.
            WindowStepperField(text: $entry, placeholder: "17:30", label: field.rawValue,
                               stepLabel: "Adjust \(field.rawValue) by five minutes", canStep: value != nil,
                               stepValue: stepperValue, bounds: 0...1439, focus: $fieldFocused)
            if value == nil {
                Text("Enter a 24-hour time, like 17:30.").font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.warning)
            }
            #else
            DatePicker(field.rawValue, selection: $draft, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField).labelsHidden().accessibilityLabel(field.rawValue).focused($fieldFocused)
            #endif
            Text(explanation)
                .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            #if WINDOW_TARAS_NATIVE
            WindowDialogActions(palette: palette, canConfirm: value != nil, cancel: { dismiss() }, confirm: {
                guard let value else { return }; minutes = value; dismiss()
            })
            #else
            WindowDialogActions(palette: palette, cancel: { dismiss() }, confirm: { minutes = liveMinutes(draft); dismiss() })
            #endif
        }.font(WindowType.font(.text, scale: scale)).padding(20).frame(width: WindowTextMetrics.editorWidth(300, scale: scale))
            .defaultFocus($fieldFocused, true)
            // The sheet opens ready to type, with the focus ring on the field.
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }
}
struct WrapUpValueEditor: View {
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    private var palette: Palette { reading.palette }
    @Binding var minutes: Int
    @JourneyViewState private var entry: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    init(minutes: Binding<Int>) {
        self._minutes = minutes; self._entry = JourneyViewState(initialValue: String(minutes.wrappedValue))
    }
    private var value: Int? { MinuteEntry.value(entry) }
    private var stepperValue: Binding<Int> {
        Binding(get: { value ?? minutes }, set: { entry = String($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wrap-up time").font(WindowType.font(.title, scale: scale, weight: .semibold)).accessibilityAddTraits(.isHeader)
            // A value row like the times: the minutes left-aligned, "min" after them, the arrows built in.
            WindowStepperField(text: $entry, placeholder: "0", unit: "min", label: "Wrap-up minutes",
                               stepLabel: "Adjust wrap-up time by five minutes", canStep: value != nil,
                               stepValue: stepperValue, bounds: 0...30, focus: $fieldFocused)
            if value == nil {
                Text("Enter a whole number from 0 to 30.").font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.warning)
            }
            Text(WindowCopy.preparationNote)
                .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            WindowDialogActions(palette: palette, canConfirm: value != nil, cancel: { dismiss() }, confirm: {
                guard let value else { return }; minutes = value; dismiss()
            })
        }.font(WindowType.font(.text, scale: scale)).padding(20)
            .frame(width: WindowTextMetrics.editorWidth(300, scale: scale)).defaultFocus($fieldFocused, true)
            .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }
}

#if !WINDOW_TARAS_NATIVE
struct TradeoffLines: View {
    let choice: DepartureEstimate
    let baseline: DepartureEstimate
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    var body: some View {
        let tradeoff = DepartureTradeoff(choice, comparedWith: baseline)
        VStack(alignment: .leading, spacing: 4) {
            Text(tradeoff.waitMinutes > 0 ? "Leave \(tradeoff.waitMinutes) min later" : tradeoff.waitMinutes < 0 ? "Leave \(-tradeoff.waitMinutes) min sooner" : "Same departure")
            Text(tradeoff.drivingMinutesSaved > 0 ? "Drive about \(tradeoff.drivingMinutesSaved) min less" : tradeoff.drivingMinutesSaved < 0 ? "Drive about \(-tradeoff.drivingMinutesSaved) min more" : "Same estimated driving time")
            Text(tradeoff.arrivalMinutesLater > 0 ? "Arrive about \(tradeoff.arrivalMinutesLater) min later" : tradeoff.arrivalMinutesLater < 0 ? "Arrive about \(-tradeoff.arrivalMinutesLater) min sooner" : "Arrive at about the same time")
        }.font(WindowType.font(.text, scale: scale)).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
private struct DepartureOfferContent: View {
    let offer: DepartureOffer
    private var palette: Palette { reading.palette }
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leave at \(liveTime(offer.choice.departure))").font(WindowType.font(.title, scale: scale, weight: .medium))
            Text(WindowCopy.travelLine(offer.choice))
                .font(WindowType.font(.text, scale: scale)).foregroundStyle(palette.muted)
            if let baseline = offer.baseline { TradeoffLines(choice: offer.choice, baseline: baseline) }
            if offer.recovery {
                let original = offer.requestedLimits
                let accepted = RecoveryPolicy.acceptedLimits(for: offer.choice, original: original)
                Text("Requested arrival: \(liveTime(original.homeBy)).")
                if accepted.homeBy > original.homeBy { Text("Allow arrival by \(liveTime(accepted.homeBy)) for this drive, including a \(Int(accepted.buffer / 60))-minute cushion.") }
                else { Text("This leaves a \(Int(accepted.buffer / 60))-minute arrival cushion instead of \(Int(original.buffer / 60)).") }
                if accepted.latest > original.latest { Text("This also leaves after your \(liveTime(original.latest)) departure limit.") }
                Text("For this drive only. Today’s saved times and your usual times stay unchanged.").foregroundStyle(palette.muted)
            }
        }.font(WindowType.font(.text, scale: scale)).fixedSize(horizontal: false, vertical: true)
    }
}
private struct DepartureOfferView: View {
    @ObservedObject var watch: LiveWatch
    let offer: DepartureOffer
    private var palette: Palette { reading.palette }
    @Environment(\.dismiss) private var dismiss
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                DepartureOfferContent(offer: offer).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            if !watch.canAccept(offer) {
                Text(WindowCopy.offerNeedsCheck).font(WindowType.font(.caption, scale: scale))
                    .foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            WindowDialogActions(palette: palette,
                confirmTitle: watch.canAccept(offer) ? "Use this departure" : "Check departures",
                canConfirm: watch.canAccept(offer) || watch.canRecheck,
                cancel: { dismiss() }, confirm: {
                    if watch.canAccept(offer) { if watch.acceptOffer(offer) { dismiss() } }
                    else if watch.recheck(replan: watch.needsNewDeparture) { dismiss() }
                })
        }.padding(20).frame(width: WindowTextMetrics.editorWidth(340, scale: scale), height: offer.recovery ? 460 : 330)
            .foregroundStyle(palette.ink).background(palette.base)
    }
}

#endif

struct WatchDetailsView: View {
    var allowsPermissionRequest = true
    var onDone: (() -> Void)? = nil
    @ObservedObject var watch: LiveWatch
    private var palette: Palette { reading.palette }
    @Environment(\.dismiss) private var dismiss
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    /// The window grows to fit its content at every text size, and scrolls only when
    /// the screen is too short (at Largest on a 13-inch display with the Dock showing,
    /// the content needs about 890 pt). Nothing is ever squeezed: every note keeps its
    /// full height, and the cap leaves room for the real title bar, the padding (40),
    /// the heading's line, the Done capsule and the two 14 pt gaps.
    @JourneyViewState private var contentHeight: CGFloat = 0
    private var scrollCap: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        let titleBar = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                          styleMask: [.titled, .closable]).height - 100
        let heading = ceil(Scale.title * 1.25 * scale)
        return max(260, screen - titleBar - 40 - heading - 28 - WindowControlMetrics.height(scale) - 4)
    }
    private var scrolls: Bool { contentHeight > scrollCap }
    private var scrollHeight: CGFloat { min(scrollCap, contentHeight > 0 ? contentHeight : 420 * scale) }
    /// When it does scroll, the scroll view runs to the window's edges and a legacy
    /// scroller sits in the right margin, so the cards stay flush with both margins.
    private var trailingInset: CGFloat {
        guard scrolls, NSScroller.preferredScrollerStyle == .legacy else { return 20 }
        return max(0, 20 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }
    /// The panel's own Wrap up value, so details and panel can never disagree.
    private var wrapUpValue: String {
        #if WINDOW_TARAS_NATIVE
        if let row = watch.tarasPresentation.snapshot.rows.first(where: { $0.name == "Wrap up" }) { return row.value }
        #endif
        guard let plan = watch.plan, let limits = watch.limits else { return "—" }
        return limits.packing == 0 ? "—" : liveTime(plan.departure.addingTimeInterval(-limits.packing))
    }
    private struct Fact { let kicker: String; let name: String; let value: String; var dim = false }
    /// The panel's row grammar, in the order the evening runs: a mono kicker over a
    /// name, the value right-aligned in 24-hour digits.
    private var facts: [Fact] {
        let checked: String
        if watch.checking { checked = watch.pendingDeparture.map { "Checking \(liveTime($0))" } ?? "Checking Apple Maps" }
        // The kicker is the context (when traffic was last read); the row is the next check.
        else { checked = watch.batch.map { "Last check \(liveTime($0.checkedAt))" } ?? "Not checked yet" }
        var result = [Fact(kicker: checked, name: "Next check",
                           value: watch.checking ? "Now" : watch.nextCheck.map { "~" + liveTime($0) } ?? "—",
                           dim: !watch.checking && watch.nextCheck == nil)]
        if let limits = watch.limits {
            // The arrive-by the panel shows: the one you asked for, even after accepting a later drive.
            let arrival = watch.recoveryOriginalLimits ?? limits
            let packing = Int(limits.packing / 60)
            result += [Fact(kicker: "Leaving window closes", name: TimeField.latest.rawValue, value: liveTime(limits.latest)),
                       Fact(kicker: "Your limit", name: TimeField.homeBy.rawValue, value: liveTime(arrival.homeBy)),
                       Fact(kicker: packing == 0 ? "No wrap-up time set" : "−\(packing)m · wrap-up time",
                            name: "Wrap up", value: wrapUpValue, dim: wrapUpValue == "—"),
                       Fact(kicker: "Planned before \(liveTime(arrival.homeBy))", name: "Minimum spare",
                            value: "\(Int(limits.buffer / 60)) min")]
        }
        return result
    }
    private func section<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            WindowCaption(caption)
            content()
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watch details").font(WindowType.font(.title, scale: scale, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if watch.active {
                        section("This watch") {
                            VStack(spacing: 0) {
                                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                                    WindowFactRow(kicker: fact.kicker, name: fact.name, value: fact.value,
                                                  dim: fact.dim, first: index == 0)
                                }
                            }.windowBox(palette)
                            if let reason = watch.pauseReason { note(reason) }
                            if watch.proposal != nil { note(watch.departureAcceptanceNote) }
                            if watch.limits != nil { note("The minimum spare is a planning allowance, not an on-time guarantee.") }
                        }
                    } else { note("No active watch. A new watch never starts automatically.") }
                    section("Alerts") {
                        VStack(spacing: 0) {
                            WindowFactRow(kicker: "macOS", name: "Notifications", value: watch.alertShortStatus, first: true)
                        }.windowBox(palette)
                        if let error = watch.alertError { note(error) }
                        HStack(spacing: 8) {
                            if watch.alertAuthorization == .denied {
                                Button("Notification Settings") { openWindowNotificationSettings() }.windowActionStyle(palette, kind: .secondary)
                            }
                            else if allowsPermissionRequest && watch.alertAuthorization != .allowed {
                                Button(watch.requestingAlertPermission ? "Requesting permission…" : "Enable alerts") { watch.updateAuthorization(request: true) }
                                    .windowActionStyle(palette, kind: .secondary)
                                    .disabled(watch.testingAlert || watch.requestingAlertPermission)
                            }
                            Button(watch.testingAlert ? "Sending test alert…" : "Send test alert") {
                                Task { _ = await watch.testAlert() }
                            }.windowActionStyle(palette, kind: .secondary)
                                .disabled(watch.testingAlert || (!allowsPermissionRequest && watch.alertAuthorization != .allowed))
                        }.padding(.top, 2)
                        if !watch.testAlertMessage.isEmpty { note(watch.testAlertMessage) }
                    }
                    section("Privacy") { note(WindowCopy.privacy) }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = ceil($0) }
                    .padding(.leading, 20).padding(.trailing, trailingInset)
            }.scrollBounceBehavior(.basedOnSize).frame(height: scrollHeight)
                // When it scrolls, say so: a visible scroller, flashed on open, and the
                // native rule between the scrolling content and the button row.
                .scrollIndicators(scrolls ? .visible : .automatic)
                .scrollIndicatorsFlash(onAppear: true)
                .overlay(alignment: .bottom) {
                    if scrolls { Rectangle().fill(palette.rule).frame(height: 1).allowsHitTesting(false) }
                }
                .padding(.horizontal, -20)
            HStack {
                Spacer()
                Button("Done") { if let onDone { onDone() } else { dismiss() } }.windowActionStyle(palette).keyboardShortcut(.defaultAction)
            }
        }.font(WindowType.font(.text, scale: scale)).padding(20)
            .frame(width: WindowTextMetrics.editorWidth(340, scale: scale), alignment: .topLeading)
            .onExitCommand { if let onDone { onDone() } else { dismiss() } }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
@MainActor func openWindowNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
}
struct LiveSettingsView: View {
    @ObservedObject var watch: LiveWatch
    @AppStorage("window.textScale") private var textScale = 1.0
    var body: some View {
        LiveSettingsContent(watch: watch, textScale: $textScale)
            .windowReadingSurface(appearance: watch.settings.appearance)
            .environment(\.windowTextScale, WindowTextMetrics.normalized(CGFloat(textScale)))
            // Tall enough for every row at every text size, including the usual-journey
            // actions that appear only sometimes; the grouped form still scrolls if it must.
            .frame(width: WindowTextMetrics.editorWidth(440, scale: scale), height: height)
    }
    private var scale: CGFloat { WindowTextMetrics.normalized(CGFloat(textScale)) }
    private var height: CGFloat {
        var usualRows: CGFloat = 0
        if watch.hasTodayTimes { usualRows += 1 }
        if watch.settings.routeID != nil && watch.settings.routeID != watch.usualSettings.routeID { usualRows += 1 }
        if watch.usualSettingsNotice != nil { usualRows += 1 }
        #if WINDOW_TARAS_NATIVE
        let base: CGFloat = 360
        #else
        let base: CGFloat = 450
        #endif
        return base + (scale - 1) * 170 + (usualRows > 0 ? (56 + usualRows * 46) * scale : 0)
    }
}
private struct LiveSettingsContent: View {
    @ObservedObject var watch: LiveWatch
    @Binding var textScale: Double
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    private var palette: Palette { reading.palette }
    /// The notification state as one short value, like the panel's status words.
    private var notificationStatus: (label: String, ok: Bool) {
        switch watch.alertAuthorization {
        case .allowed: return watch.alertError == nil ? ("Allowed", true) : ("Last alert failed", false)
        case .denied: return ("Off", false)
        case .unknown: return ("Not set up", false)
        case .unavailable: return ("Unavailable", false)
        }
    }
    private var showsUsualJourney: Bool {
        watch.hasTodayTimes || (watch.settings.routeID != nil && watch.settings.routeID != watch.usualSettings.routeID)
            || watch.usualSettingsNotice != nil
    }
    var body: some View {
        Form {
            #if !WINDOW_TARAS_NATIVE
            Section {
                Picker("Appearance", selection: $watch.settings.appearance) {
                    Text("Follow system").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
            } header: { WindowCaption("Appearance") }
            #endif
            Section {
                HStack(spacing: 10) {
                    Text("Text size")
                    Spacer(minLength: 8)
                    WindowCapsuleChoice(selection: $textScale,
                                        options: [(title: "Standard", value: 1.0), (title: "Larger", value: 1.2), (title: "Largest", value: 1.4)])
                        .accessibilityLabel("Text size")
                }
                Group {
                    #if WINDOW_TARAS_NATIVE
                    Text("Applies to journey setup, Settings and watch details.")
                    #else
                    Text("Applies to your journey, Settings and editors. Resize the main window for more room.")
                    #endif
                }.font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
            } header: { WindowCaption("Reading") }
            // Shown only when there is something to save for future days.
            if showsUsualJourney {
                Section {
                    if watch.hasTodayTimes {
                        Button("Make today’s times my usual times") { _ = watch.makeUsualTimes() }.windowActionStyle(palette, kind: .secondary)
                    }
                    if watch.settings.routeID != nil && watch.settings.routeID != watch.usualSettings.routeID {
                        Button("Make today’s route my usual route") { watch.makeUsualRoute() }.windowActionStyle(palette, kind: .secondary)
                    }
                    if let notice = watch.usualSettingsNotice { Text(notice).font(WindowType.font(.caption, scale: scale)) }
                } header: { WindowCaption("Usual journey") }
            }
            Section {
                HStack(spacing: 6) {
                    Text("Notifications")
                    Spacer(minLength: 8)
                    Text(notificationStatus.label).foregroundStyle(notificationStatus.ok ? palette.ink : palette.muted)
                    Image(systemName: notificationStatus.ok ? "checkmark" : "xmark")
                        .font(.system(size: Scale.caption * scale, weight: .semibold))
                        .foregroundStyle(notificationStatus.ok ? palette.watching : palette.muted)
                        .accessibilityHidden(true)
                }.accessibilityElement(children: .combine)
                if let error = watch.alertError {
                    Text(error).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Notification Settings") { openWindowNotificationSettings() }.windowActionStyle(palette, kind: .secondary)
                Text("Keep Window running and online for alerts to arrive. Focus can silence them.")
                    .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
            } header: { WindowCaption("Notifications") }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .font(WindowType.font(.text, scale: scale))
    }
}

struct LiveRouteEditor: View {
    private var palette: Palette { reading.palette }
    @Binding var journey: SavedJourney
    @StateObject private var search = PlaceSearch()
    @JourneyViewState private var draft: SavedJourney
    @JourneyViewState private var query = ""
    @JourneyViewState private var origin = true
    @JourneyViewState private var selectedResult: String?
    private enum Focus: Hashable { case query, done }
    @FocusState private var focus: Focus?
    @Environment(\.dismiss) private var dismiss
    var reading = WindowReadingContext()
    private var scale: CGFloat { reading.scale }
    init(journey: Binding<SavedJourney>) {
        self._journey = journey; self._draft = JourneyViewState(initialValue: journey.wrappedValue)
    }
    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { value in
            guard query != value else { return }
            clearSearch(); query = value; search.complete(value)
        })
    }
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var samePlace: Bool { draft.origin != nil && draft.origin?.id == draft.destination?.id }
    private var canConfirm: Bool { draft.routeID != nil && !samePlace && !search.busy && !hasQuery }
    private func clearSearch() {
        search.cancel(); search.complete(""); search.results = []; search.error = nil; selectedResult = nil
    }
    private func submitSearch() {
        guard !search.busy, hasQuery else { return }
        if let selectedResult, let place = search.results.first(where: { $0.id == selectedResult }) {
            select(place)
        } else { selectedResult = nil; search.find(query) }
    }
    private func select(_ place: SavedPlace) {
        guard !search.busy, search.results.contains(where: { $0 == place }) else { return }
        if origin { draft.origin = place; origin = false }
        else { draft.destination = place }
        clearSearch(); query = ""
        focus = draft.destination == nil || samePlace ? .query : .done
    }
    /// The saved address under the name, unless it only repeats the name.
    private static func shownAddress(_ place: SavedPlace) -> String? {
        let address = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty || address == place.name ? nil : address
    }
    /// The panel's row grammar: a mono kicker (FROM, TO) over the place, then its address.
    private func endpointSummary(_ title: String, place: SavedPlace?, mark: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                WindowKicker(title).padding(.bottom, 1 * scale)
                Text(place?.name ?? "Choose a place").fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                if let address = place.flatMap(Self.shownAddress) {
                    Text(address).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            // The "change place" mark on the other row; the one being edited has its field.
            if mark { Image(systemName: "magnifyingglass").foregroundStyle(palette.muted).accessibilityHidden(true) }
        }
    }
    /// The place being edited holds the search; the other is one press away.
    @ViewBuilder private func endpoint(_ title: String, place: SavedPlace?, isOrigin: Bool) -> some View {
        let card = RoundedRectangle(cornerRadius: Palette.radius)
        if origin == isOrigin {
            VStack(alignment: .leading, spacing: 10 * scale) {
                endpointSummary(title, place: place, mark: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title). \(place?.name ?? "Not selected"). \(place.flatMap(Self.shownAddress) ?? "")")
                    .accessibilityValue("Editing this place")
                searchRow
            }
            .padding(10 * scale).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.fieldHover, in: card)
            .overlay(card.stroke(palette.rule))
        } else {
            Button {
                origin = isOrigin; clearSearch(); query = ""; focus = .query
            } label: {
                endpointSummary(title, place: place).padding(10 * scale).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(WindowRowButton(palette: palette))
                .background(palette.field, in: card)
                .overlay(card.stroke(palette.rule))
                .accessibilityLabel("\(title). \(place?.name ?? "Not selected"). \(place.flatMap(Self.shownAddress) ?? ""). Change place.")
        }
    }
    /// One search field, as macOS draws it: the magnifier inside, Return searches (or
    /// confirms, when empty), and a clear button once there is text. No separate capsule.
    private var searchRow: some View {
        HStack(alignment: .center, spacing: 6 * scale) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                .accessibilityHidden(true)
                .onTapGesture { focus = .query }
            // FROM / TO above already say which end; the prompt fits at every text size.
            TextField("Place or address", text: queryBinding)
                .focused($focus, equals: .query)
                .accessibilityLabel(origin ? "Search for the starting place" : "Search for the destination")
                .onSubmit {
                    if !hasQuery && canConfirm { journey = draft; dismiss() }
                    else { submitSearch() }
                }
                .onMoveCommand { direction in
                    guard !search.busy, direction == .up || direction == .down else { return }
                    selectedResult = ResultSelection.moved(selectedResult, in: search.results.map(\.id),
                        direction: direction == .up ? -1 : 1)
                }
            if hasQuery || search.busy {
                Button {
                    clearSearch(); query = ""; focus = .query
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(palette.muted)
                    .help(search.busy ? "Cancel search" : "Clear")
                    .accessibilityLabel(search.busy ? "Cancel place search" : "Clear place search")
            }
        }
        .windowFieldChrome(focused: focus == .query, onCard: true)
    }
    /// Rows shown under the places: suggestions while typing, then Maps results.
    private var listedCount: Int { search.results.count + (search.results.isEmpty && hasQuery && !search.busy ? search.suggestions.count : 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your route").font(WindowType.font(.title, scale: scale, weight: .semibold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                endpoint("From", place: draft.origin, isOrigin: true)
                endpoint("To", place: draft.destination, isOrigin: false)
            }
            if search.busy { ProgressView("Searching Apple Maps…").controlSize(.small) }
            if let error = search.error {
                Text(error).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if samePlace {
                Text("Choose two different places.").font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.warning)
            } else if hasQuery && !search.busy {
                Text("Choose a result, or clear the search to keep the confirmed places.")
                    .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if listedCount > 0 {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if search.results.isEmpty && !search.busy && hasQuery {
                                ForEach(search.suggestions) { suggestion in
                                    Button {
                                        query = suggestion.query; selectedResult = nil; search.find(suggestion.query)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(suggestion.title).fontWeight(.medium)
                                            if !suggestion.subtitle.isEmpty {
                                                Text(suggestion.subtitle).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.buttonStyle(WindowRowButton(palette: palette))
                                        .accessibilityLabel(suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title). \(suggestion.subtitle)")
                                        .accessibilityHint("Searches Apple Maps for this place.")
                                }
                            }
                            ForEach(search.results) { place in
                                Button { select(place) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(place.name).fontWeight(.medium)
                                        Text(place.address).font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.buttonStyle(WindowRowButton(palette: palette, selected: selectedResult == place.id))
                                    .accessibilityLabel("\(place.name). \(place.address)")
                                    .accessibilityValue(selectedResult == place.id ? "Selected search result" : "")
                                    .id(place.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollBounceBehavior(.basedOnSize)
                        // Grows with the list up to about four rows, then scrolls.
                        .frame(height: min(CGFloat(listedCount) * 50, 220) * scale)
                        .onChange(of: selectedResult) { _, id in if let id { scroller.scrollTo(id, anchor: .center) } }
                }
            }
            Text("What you type goes to Apple Maps for suggestions. Choose the result with the correct address.")
                .font(WindowType.font(.caption, scale: scale)).foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { dismiss() }
                    .windowActionStyle(palette, kind: .secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { guard canConfirm else { return }; journey = draft; dismiss() }
                    .windowActionStyle(palette)
                    .disabled(!canConfirm).focused($focus, equals: .done)
                    // Return in the search field searches (or confirms, when empty) through onSubmit.
                    .keyboardShortcut(focus == .query ? nil : KeyboardShortcut.defaultAction)
            }
        }.font(WindowType.font(.text, scale: scale)).padding(20)
            // Sized by its content: the actions sit right under the places.
            .frame(width: WindowTextMetrics.editorWidth(380, scale: scale), alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .defaultFocus($focus, .query)
            .onAppear { DispatchQueue.main.async { focus = .query } }
            .onChange(of: search.results.map(\.id)) { _, ids in
                if let selectedResult, ids.contains(selectedResult) { return }
                selectedResult = ids.first
            }
            .onDisappear { clearSearch() }
    }
}

/// The existing AppKit shell hosts the same root in both places. Inspect the
/// actual owner, not a guessed window class or screen dimensions. Snapshot hosts
/// have no owning popover and stay in the main-window composition.
#if !WINDOW_TARAS_NATIVE
private struct WindowSurfaceProbe: NSViewRepresentable {
    let changed: (Bool) -> Void
    let closed: () -> Void
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); view.changed = changed; view.closed = closed; return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.closed = closed }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }
    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        var closed: (() -> Void)?
        private var closeObserver: NSObjectProtocol?
        private var generation = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Keep the close observer through a transient detach; didClose can
            // follow the content view losing its window during the animation.
            guard window != nil else { return }
            stopObserving()
            let version = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, version == self.generation, let window = self.window else { return }
                let owner = NSApp.delegate as? AppDelegate
                let isPanel = owner?.popover.contentViewController?.view.window === window
                self.changed?(isPanel)
                guard isPanel, let popover = owner?.popover else { return }
                self.closeObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification,
                    object: popover, queue: .main) { [weak self, weak popover] _ in
                        guard let self, version == self.generation, popover?.isShown == false else { return }
                        self.closed?()
                    }
            }
        }
        func stopObserving() {
            generation += 1
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
}

private struct CanopyBackground: View {
    let palette: Palette
    let dark: Bool
    let date: Date
    @Environment(\.colorSchemeContrast) private var contrast
    private var study: Bool { CommandLine.arguments.contains("--canopy-study") }
    var body: some View {
        ZStack(alignment: .top) {
            palette.base
            if contrast != .increased, let image = dark ? Art.dark : Art.light {
                Image(nsImage: image).resizable().scaledToFill().frame(height: 118).clipped()
                    .overlay {
                        // An opt-in lighting study, not live weather or an inferred sunset.
                        // The approved artwork and shipped appearance remain unchanged by default.
                        if study {
                            LinearGradient(colors: [studyColor.opacity(dark ? 0.12 : 0.08), .clear], startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .mask(LinearGradient(stops: [.init(color: .white.opacity(0.62), location: 0), .init(color: .white.opacity(0.48), location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var studyColor: Color {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 17 { return Color(red: 0.94, green: 0.76, blue: 0.42) }
        if hour < 19 { return Color(red: 0.83, green: 0.47, blue: 0.35) }
        return Color(red: 0.35, green: 0.43, blue: 0.61)
    }
}

/// Uses production views and isolated test fixtures. These captures are for
/// reviewing copy/layout, not proof of native glass, focus or VoiceOver behavior.
@MainActor func presentationReviewViews(watch: LiveWatch, scale: CGFloat) -> [(String, AnyView, NSSize)] {
    let editor = WindowTextMetrics.editorWidth(300, scale: scale)
    let details = WindowTextMetrics.editorWidth(340, scale: scale)
    var result: [(String, AnyView, NSSize)] = [
        ("settings", AnyView(LiveSettingsContent(watch: watch, textScale: .constant(Double(scale)))), NSSize(width: 440, height: 400)),
        ("details", AnyView(WatchDetailsView(watch: watch)), NSSize(width: details, height: 490)),
        ("route", AnyView(LiveRouteEditor(journey: .constant(watch.settings))), NSSize(width: WindowTextMetrics.editorWidth(380, scale: scale), height: 430 + 300 * (scale - 1))),
        ("wrap-up", AnyView(WrapUpValueEditor(minutes: .constant(5))), NSSize(width: editor, height: 280 + 200 * (scale - 1))),
        ("native-controls", AnyView(WindowControlReview()), NSSize(width: details, height: 370 + 300 * (scale - 1))),
        ("inside-window", AnyView(InsideWindowView()), NSSize(width: details, height: 400 + 100 * (scale - 1))),
        ("canopy-bird", AnyView(CanopyBirdDrawing(pose: CanopyBirdPose(), palette: Palette(dark: watch.settings.appearance == "Dark"), cover: true)), NSSize(width: 256, height: 132))
    ]
    for field in TimeField.allCases {
        result.append(("time-" + field.id.lowercased().replacingOccurrences(of: " ", with: "-"),
                       AnyView(TimeValueEditor(field: field, minutes: .constant(1050), day: watch.now)),
                       NSSize(width: editor, height: 240 + 200 * (scale - 1))))
    }
    if let plan = watch.plan, let offer = watch.offer(for: plan) {
        result.append(("offer", AnyView(DepartureOfferView(watch: watch, offer: offer)), NSSize(width: details, height: 330)))
    }
    return result
}

#endif
