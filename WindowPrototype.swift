// Native Window shell, shared visual components, and the isolated interaction demo.
import SwiftUI
import AppKit
import Combine

/// Follows the system hour cycle. Tests and snapshots may override it.
#if WINDOW_NATIVE
/// The shipped app uses one clock everywhere: the ruler's 24-hour time.
var uses24Hour: Bool = true
#else
var uses24Hour: Bool = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h").contains("a") == false
#endif
func time(_ minute: Int) -> String {
    let h = (minute / 60) % 24, m = String(format: "%02d", minute % 60)
    return uses24Hour ? String(format: "%02d:%@", h, m) : "\(h % 12 == 0 ? 12 : h % 12):\(m)"
}
func meridiem(_ minutes: Int) -> String { uses24Hour ? "" : (minutes < 720 ? "AM" : "PM") }
/// Time as VoiceOver should say it: "5:30 PM", or "17:30".
func spoken(_ minutes: Int) -> String { meridiem(minutes).isEmpty ? time(minutes) : "\(time(minutes)) \(meridiem(minutes))" }

#if !WINDOW_NATIVE
enum Scenario: String, CaseIterable { case normal = "Normal traffic", flat = "No benefit", incident = "Traffic worsens", offline = "Offline / asleep", denied = "Notifications denied" }
struct Option { let departure: Int; let drive: Int; var arrival: Int { departure + drive } }
@MainActor final class Journey: ObservableObject {
    @Published var origin = "Office"
    @Published var destination = "Home"
    @Published var earliest = 1030
    @Published var latest = 1060
    @Published var homeBy = 1095
    @Published var packing = 5
    @Published var now = 1025
    @Published var screen = "setup"
    @Published var scenario: Scenario = .normal
    @Published var appearance = "System"
    @Published var departure: Int? = nil   // the committed plan; survives clock ticks
    @Published var baseline: Int? = nil    // "leave as soon as ready" when the watch began; the fixed comparison
    @Published var lastCheck: Int? = nil
    @Published var notice = ""             // one label-style line for the status slot; cleared by the next tick
    @Published var endTitle = ""
    @Published var endIcon = ""
    @Published var showInspector = false
    var validation: String? {
        if origin.trimmingCharacters(in: .whitespaces).isEmpty || destination.trimmingCharacters(in: .whitespaces).isEmpty { return "Give both places a name." }
        if earliest > latest { return "“Latest leave” must come after “Earliest leave”." }
        if latest >= homeBy { return "“Arrive by” must come after “Latest leave”." }
        return nil
    }
    var ready: Int { max(earliest, now + packing) }   // readiness for a new plan only; never applied to a committed one
    func duration(_ departure: Int) -> Int {
        switch scenario {
        case .incident: return 62
        case .flat: return 42
        default: return max(30, 55 - max(0, departure - 1030) * 5 / 4)
        }
    }
    func option(_ departure: Int) -> Option { Option(departure: departure, drive: duration(departure)) }
    func feasible(_ o: Option) -> Bool { o.departure <= latest && o.arrival + 10 <= homeBy }
    /// The demo follows the live policy: earliest arrival, then earliest departure.
    func plan(from start: Int) -> Option? {
        guard start <= latest else { return nil }
        return stride(from: start, through: latest, by: 5).map(option).filter(feasible)
            .min { $0.arrival == $1.arrival ? $0.departure < $1.departure : $0.arrival < $1.arrival }
    }
    var immediate: Option { option(ready) }
    var ideal: Option? { plan(from: ready) }
    var committed: Option? { departure.map(option) }
    var base: Option? { baseline.map(option) }
    var missed: Bool { departure.map { now > $0 } ?? false }
    var stale: Bool { scenario == .offline || lastCheck.map { now - $0 > 10 } ?? false }
    var risk: Bool { committed.map { !feasible($0) } ?? (ideal == nil) }
    var wrapUp: Bool { committed.map { now >= $0.departure - packing } ?? false }
    /// Five minutes later than the plan (or than readiness), if that still fits the limits.
    var later: Option? { let o = option((departure ?? ready) + 5); return feasible(o) ? o : nil }
    var canDelay: Bool { later != nil }
    /// Which layout the watching screen shows; the view animates on this.
    var phase: String { stale ? "stale" : (committed != nil && !risk) ? (wrapUp ? "wrapup" : "plan") : "risk" }
    var status: String {
        if screen == "finished" { return "This watch has ended" }
        if stale { return "Watching paused · plan unconfirmed" }
        if risk { return "Your arrival needs attention" }
        if scenario == .denied { return "Alerts are off · no cue at wrap-up" }
        return "Watching · checked \(lastCheck.map(time) ?? "—")"
    }
    /// Menu-bar text beside the mark; empty when nothing is being watched. Stays live while the person looks at settings.
    var menuTitle: String {
        guard watchActive else { return "" }
        if stale { return " Paused" }
        if risk { return " Leave now" }
        if wrapUp { return " Wrap up" }
        return committed.map { " Leave \(time($0.departure))" } ?? ""
    }
    var watchActive: Bool { baseline != nil }
    /// Starts a watch, or returns to one. Looking at settings never changes a plan that still fits; edits that break it replan.
    func start() {
        guard validation == nil else { return }
        screen = "watch"; lastCheck = nil; notice = ""
        if !watchActive { baseline = ready; departure = nil }
        else if let current = committed, !feasible(current) || missed { departure = nil; notice = "Limits changed · replanned from now" }
        refresh()
    }
    /// A committed departure changes only for an explicit reason: it passed, it no longer fits, the person asked for time, or the person chose another.
    /// ponytail: no "traffic improved" replanning; add a threshold rule when a real provider supplies changing estimates.
    func refresh() {
        guard screen == "watch", scenario != .offline else { return }   // age-stale clears on a successful check; offline blocks it
        lastCheck = now
        guard let current = committed else { departure = ideal?.departure; return }
        if missed { departure = ideal?.departure; notice = "\(time(current.departure)) passed · replanned from now" }
        else if !feasible(current) { departure = ideal?.departure }
    }
    /// One simulated tick. A tick retires the previous notice so the status line returns to the check time.
    func advance(_ minutes: Int) { guard screen == "watch" else { return }; notice = ""; now += minutes; refresh() }
    /// Exactly five minutes later, if that still fits. The label promises five, so it moves five.
    func delay() {
        if let later { departure = later.departure; notice = "Moved to \(time(later.departure)) · limits still hold" }
        else { notice = "No later departure fits your limits" }
    }
    func choose(_ departure: Int) { self.departure = departure; notice = ""; refresh() }
    func finish(_ title: String, _ message: String, icon: String) { screen = "finished"; endTitle = title; notice = message; endIcon = icon; departure = nil; baseline = nil }
    func reset() { screen = "setup"; now = 1025; scenario = .normal; departure = nil; baseline = nil; lastCheck = nil; notice = "" }
    var payload: String { "state=\(screen)\nscenario=\(scenario.rawValue)\nclock=\(time(now)) · ready=\(time(ready))\nlimits=\(time(earliest))…\(time(latest)); home=\(time(homeBy))\npacking=\(packing)m; buffer=10m\ncommitted=\(departure.map(time) ?? "none"); baseline=\(baseline.map(time) ?? "none")\nlastCheck=\(lastCheck.map(time) ?? "none")\nsource=simulated fixture; stored=false" }
}

#endif

#if !WINDOW_NATIVE
/// 5 × 7 dot-matrix digits. Each glyph advances 6 cells (5 plus a gap); the colon advances 2. Dots sit centered in their cells.
struct DotTime: View {
    var text: String
    var color: Color
    var height: CGFloat
    static let glyphs: [Character: [String]] = [
        "0":["01110","10001","10001","10001","10001","10001","01110"],
        "1":["00100","01100","00100","00100","00100","00100","01110"],
        "2":["01110","10001","00001","00010","00100","01000","11111"],
        "3":["11110","00001","00001","01110","00001","00001","11110"],
        "4":["00010","00110","01010","10010","11111","00010","00010"],
        "5":["11111","10000","10000","11110","00001","00001","11110"],
        "6":["01110","10000","10000","11110","10001","10001","01110"],
        "7":["11111","00001","00010","00100","01000","01000","01000"],
        "8":["01110","10001","10001","01110","10001","10001","01110"],
        "9":["01110","10001","10001","01111","00001","00001","01110"],
        ":":["0","0","1","0","1","0","0"]]
    static func advance(_ c: Character) -> Int { c == ":" ? 2 : 6 }
    var cells: Int { max(0, text.reduce(0) { $0 + Self.advance($1) } - 1) }   // no trailing gap
    var width: CGFloat { CGFloat(cells) * height / 7 }
    var body: some View {
        Canvas { context, _ in
            let cell = height / 7, dot = cell * 0.75, inset = cell * 0.125
            var x: CGFloat = 0
            for character in text {
                if let rows = Self.glyphs[character] {
                    for (row, bits) in rows.enumerated() {
                        for (column, bit) in bits.enumerated() where bit == "1" {
                            context.fill(Path(ellipseIn: CGRect(x: x + CGFloat(column) * cell + inset, y: CGFloat(row) * cell + inset, width: dot, height: dot)), with: .color(color))
                        }
                    }
                }
                x += cell * CGFloat(Self.advance(character))
            }
        }.frame(width: width, height: height).accessibilityHidden(true)
    }
}
#endif

extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) } }
extension NSColor { convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) } }

/* ─────────────────────────────────────────────────────────────
 * MOTION STORYBOARD
 *
 * Every duration, spring, and offset lives in `Motion`; nothing inline.
 *
 *   screen change   old screen fades out; new screen fades in and
 *                   settles up 8 pt          spring 0.45 s, light bounce
 *   phase change    plan ↔ wrap-up ↔ paused ↔ attention use the same
 *                   cross-fade inside the watching screen
 *   plan change     departure digits, driving line, benefit, and limits
 *                   cross-fade in place                          0.30 s
 *   wrap-up cue     the cue line turns accent and scales 0.96 → 1
 *   press           every button dims to 0.85; the primary also
 *                   settles to 0.98 (not under Reduce Motion)    0.12 s
 *   hover           quiet buttons shift to accent; fields lift    0.12 s
 *   Reduce Motion   every change becomes a 0.15 s cross-fade, no offsets
 *
 * SEQUENCES
 *   start           press settles → setup fades out while the watching
 *                   screen and header status rise in
 *   wrap-up         status text cross-fades, cue scales in, menu bar
 *                   reads "Wrap up", VoiceOver announces once
 *   delay           digits cross-fade to the new time, status line
 *                   explains the move for one tick, actions row swaps
 *   settings        gear → setup; "Back to my watch" returns with the
 *                   same plan unless an edit made it infeasible
 * ───────────────────────────────────────────────────────────── */
enum Motion {
    static let screen = Animation.spring(duration: 0.45, bounce: 0.1)
    static let value = Animation.easeInOut(duration: 0.30)
    static let press = Animation.easeOut(duration: 0.12)
    static let reduced = Animation.easeInOut(duration: 0.15)
    static let screenOffset: CGFloat = 8
    static let pressScale: CGFloat = 0.98
    static let pressDim: Double = 0.85
    static let cueScale: CGFloat = 0.96
}
/// Six text sizes. Actions use `text` at medium weight (the inline status action uses `caption`); supporting information uses `caption` in the muted color.
enum Scale {
    static let display: CGFloat = 24, title: CGFloat = 17, body: CGFloat = 15, text: CGFloat = 13, caption: CGFloat = 12, label: CGFloat = 10
}
private struct WindowTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var windowTextScale: CGFloat {
        get { self[WindowTextScaleKey.self] }
        set { self[WindowTextScaleKey.self] = newValue }
    }
}
struct Palette {
    let dark: Bool
    var highContrast = false
    static let disabled: Double = 0.45
    static let radius: CGFloat = 8
    #if WINDOW_NATIVE
    // The shipped app's deeper windows wear the panel's tokens (PanelView).
    static let baseDark: UInt32 = 0x1C1C1E, accentDark: UInt32 = 0xF7773D  // panel orange, nudged to 4.5:1 on hover fills
    var ink: Color { Color(hex: dark ? 0xF2F2F7 : 0x1C1C1E) }
    var muted: Color { highContrast ? ink : Color(hex: dark ? 0xA1A1A6 : 0x5E5E63) }
    var base: Color { Color(hex: dark ? Self.baseDark : 0xF5F5F7) }
    var accent: Color { Color(hex: dark ? Self.accentDark : 0xA83E0C) }
    var watching: Color { Color(hex: dark ? 0x30D158 : 0x248A3D) }
    var warning: Color { Color(hex: dark ? 0xFFD60A : 0x985100) }
    #else
    static let baseDark: UInt32 = 0x090D0E, accentDark: UInt32 = 0xF3DCA5
    var ink: Color { Color(hex: dark ? 0xECEBE4 : 0x25302E) }
    var muted: Color { highContrast ? ink : Color(hex: dark ? 0xADB4B4 : 0x59635F) }
    var base: Color { Color(hex: dark ? Self.baseDark : 0xF4F1E8) }
    var accent: Color { Color(hex: dark ? Self.accentDark : 0x795B28) }
    var watching: Color { Color(hex: dark ? 0xA8BF95 : 0x637C51) }
    var warning: Color { Color(hex: dark ? 0xFFB35C : 0x985100) }
    #endif
    var error: Color { dark ? .red : Color(hex: 0xA6261F) }           // ≈ 6:1 on the light base
    var rule: Color { ink.opacity(highContrast ? 0.4 : 0.17) }
    var field: Color { ink.opacity(dark ? 0.06 : 0.03) }
    var fieldHover: Color { ink.opacity(dark ? 0.11 : 0.06) }
    /// The panel's capsule ring (#717178 on #1C1C1E at rest, #85858B on hover).
    var capsuleRing: Color { ink.opacity(highContrast ? 0.8 : 0.40) }
    var capsuleRingHover: Color { ink.opacity(highContrast ? 0.9 : 0.49) }
}
#if !WINDOW_NATIVE
/// Decorative canopy artwork, decoded once.
enum Art {
    static let dark = load("canopy-dark"), light = load("canopy-light")
    static func load(_ name: String) -> NSImage? { Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) } }
}

/// Native controls own focus, pressed feedback, and glass; content keeps its solid background.
struct PrimaryButton: PrimitiveButtonStyle {
    let palette: Palette
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isEnabled) private var enabled
    @Environment(\.windowTextScale) private var textScale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(action: configuration.trigger) {
            configuration.label.font(.system(size: Scale.body * textScale, weight: .medium))
                .foregroundStyle(appearsActive && enabled ? palette.base : palette.ink).frame(maxWidth: .infinity).padding(.vertical, 5)
        }.tint(palette.accent).controlSize(.large)
        if #available(macOS 26, *), !reduceTransparency && contrast != .increased {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
struct WindowControlButton: PrimitiveButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *), !reduceTransparency && contrast != .increased {
            Button(configuration).buttonStyle(.glass)
        } else { Button(configuration).buttonStyle(.bordered) }
    }
}
/// Text or icon button with no chrome. Rests in ink (or the given color), shifts to the accent on hover, dims on press and when disabled.
/// The vertical inset makes the hit area at least 22 pt tall without changing the label.
struct QuietButton: ButtonStyle {
    let palette: Palette
    var size: CGFloat = Scale.text
    var weight: Font.Weight = .medium
    var color: Color? = nil
    var inset: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, style: self) }
    struct Styled: View {
        let configuration: Configuration, style: QuietButton
        @Environment(\.isEnabled) private var enabled
        @Environment(\.windowTextScale) private var textScale
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: style.size * textScale, weight: style.weight))
                .foregroundStyle(hover && enabled ? style.palette.accent : (style.color ?? style.palette.ink))
                .opacity(configuration.isPressed ? Motion.pressDim : (enabled ? 1 : Palette.disabled))
                .padding(.vertical, style.inset).frame(minHeight: 22)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6))
                .onHover { hover = $0 }
                .animation(Motion.press, value: hover)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}
/// Bordered value box used by every time control in setup. Lifts on hover, dims on press.
struct FieldButton: ButtonStyle {
    let palette: Palette
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, palette: palette) }
    struct Styled: View {
        let configuration: Configuration, palette: Palette
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(hover ? palette.fieldHover : palette.field, in: RoundedRectangle(cornerRadius: Palette.radius))
                .overlay(RoundedRectangle(cornerRadius: Palette.radius).stroke(palette.rule))
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Palette.radius))
                .opacity(configuration.isPressed ? Motion.pressDim : 1)
                .onHover { hover = $0 }
                .animation(Motion.press, value: hover)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

enum PreferencesAnchor { case gear, packing }
enum RouteField { case from, to }
#endif

enum TimeField: String, Identifiable, CaseIterable {
    // Chronological, in the panel's words: earliest leave, leave by, arrive by.
    case earliest = "Earliest leave", latest = "Latest leave", homeBy = "Arrive by"
    var id: String { rawValue }
    var note: String {
        switch self {
        case .homeBy: return "Window aims to get you there at least \(Int(WatchLimits.defaultBuffer / 60)) min early."
        case .earliest: return "The earliest you can actually leave, after packing up."
        case .latest: return "A hard limit. Window never recommends leaving after this."
        }
    }
}
#if !WINDOW_NATIVE
/// "Leave by 5:40 · Home by 6:15" as VoiceOver should read it.
func spokenLine(_ text: String) -> String { text.replacingOccurrences(of: " · ", with: ", ") }

struct WindowView: View {
    @ObservedObject var model: Journey
    var measuring = false   // snapshot mode: no spacer or minimum height, so the content reports its true height
    var announces = true    // only one hosted instance speaks; the menu-bar popover passes false
    @State private var showingTools = false
    @State private var editingRoute = false
    @State private var editingPreferences: PreferencesAnchor? = nil
    @FocusState private var routeFocus: RouteField?
    @State private var editingTime: TimeField? = nil
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var dark: Bool { model.appearance == "Dark" || (model.appearance == "System" && systemScheme == .dark) }
    var palette: Palette { Palette(dark: dark, highContrast: contrast == .increased) }
    var ink: Color { palette.ink }
    var muted: Color { palette.muted }
    var base: Color { palette.base }
    var accent: Color { palette.accent }
    var rule: Color { palette.rule }
    func motion(_ animation: Animation) -> Animation { reduceMotion ? Motion.reduced : animation }
    var screenTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: Motion.screenOffset)), removal: .opacity)
    }
    func announce(_ text: String) { if announces { AccessibilityNotification.Announcement(text).post() } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    ZStack(alignment: .topLeading) {
                        if model.screen == "setup" { setup.transition(screenTransition) }
                        else if model.screen == "finished" { finished.transition(screenTransition) }
                        else { watching.transition(screenTransition) }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                if !measuring { Spacer(minLength: 0) }
            }.background(alignment: .top) {
                ZStack(alignment: .top) {
                    base
                    if let art = dark ? Art.dark : Art.light {
                        Image(nsImage: art).resizable().scaledToFill().frame(height: 118).clipped()
                            .mask(LinearGradient(stops: [.init(color: .white.opacity(0.72), location: 0), .init(color: .white.opacity(0.62), location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                            .accessibilityHidden(true)
                    }
                }.allowsHitTesting(false)
            }
            .animation(motion(Motion.screen), value: model.screen)
            controls
        }.frame(minWidth: 420, minHeight: measuring ? 0 : 510).foregroundStyle(ink)
            .preferredColorScheme(model.appearance == "System" ? nil : (dark ? .dark : .light))
            .onChange(of: model.wrapUp) { _, cue in
                guard cue, model.screen == "watch", let plan = model.committed else { return }
                announce(model.packing == 0 ? "Leave now." : "Time to wrap up. Leave at \(spoken(plan.departure)).")
            }
            .onChange(of: model.departure) { old, new in
                guard model.screen == "watch", let new, old != nil else { return }
                announce("Plan updated. Leave at \(spoken(new)).")
            }
            .onChange(of: model.status) { _, status in
                guard model.screen == "watch" else { return }
                announce(spokenLine(status))
            }
    }
    var mark: some View {
        VStack(spacing: 3) { ForEach(0..<2) { _ in HStack(spacing: 3) { Circle().frame(width: 7, height: 7); Circle().frame(width: 7, height: 7) } } }
            .foregroundStyle(accent).accessibilityHidden(true)
    }
    var statusLine: String { !model.notice.isEmpty && model.screen == "watch" ? model.notice : model.status }
    var dotColor: Color {
        if model.screen == "finished" { return muted }
        return model.stale || model.risk || model.scenario == .denied ? palette.warning : palette.watching
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                mark
                Text("Window").font(.system(size: Scale.display, weight: .medium)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    switch model.screen {
                    case "setup": editingPreferences = .gear
                    case "finished": model.reset()
                    default: model.screen = "setup"
                    }
                } label: { Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 22, height: 20) }
                    .buttonStyle(QuietButton(palette: palette))
                    .help(model.screen == "setup" ? "Journey preferences" : "Edit journey")
                    .accessibilityLabel(model.screen == "setup" ? "Journey preferences" : "Edit journey")
                    .popover(isPresented: preferencesShown(.gear)) { preferences }
            }
            if model.screen != "setup" {
                Text("\(model.origin) → \(model.destination)").font(.system(size: Scale.text)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("\(model.origin) to \(model.destination)")
                    .transition(screenTransition)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)   // bottom on the baseline centers it on the x-height
                        .accessibilityHidden(true)
                    Text(statusLine).font(.system(size: Scale.caption)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .accessibilityLabel(spokenLine(statusLine))
                    if model.screen == "watch", model.scenario == .denied, !model.stale, !model.risk {
                        Text("·").font(.system(size: Scale.caption)).foregroundStyle(muted).accessibilityHidden(true)
                        Button("Enable alerts") { model.scenario = .normal; model.refresh() }
                            .buttonStyle(QuietButton(palette: palette, size: Scale.caption, inset: 2))
                            .help("Simulated. In the real app this opens Notification Settings.")
                    }
                }.animation(motion(Motion.value), value: statusLine).transition(screenTransition)
                Rectangle().fill(rule).frame(height: 1).transition(screenTransition)
            }
        }
    }
    func binding(_ field: TimeField) -> Binding<Int> {
        switch field { case .homeBy: return $model.homeBy; case .earliest: return $model.earliest; case .latest: return $model.latest }
    }
    func timeRow(_ field: TimeField, prominent: Bool = false) -> some View {
        let minutes = binding(field).wrappedValue
        return HStack {
            Text(field.rawValue)
                .font(.system(size: prominent ? Scale.title : Scale.text, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? ink : muted)
                .accessibilityHidden(true)   // the control's label already names the field
            Spacer()
            Button { editingTime = field } label: {
                HStack(spacing: 8) {
                    if prominent { DotTime(text: time(minutes), color: accent, height: 28) }
                    else { Text(time(minutes)).font(.system(size: Scale.body, weight: .medium).monospacedDigit()) }
                    if !meridiem(minutes).isEmpty { Text(meridiem(minutes)).font(.system(size: Scale.caption)).foregroundStyle(muted) }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                }.padding(.horizontal, 12).padding(.vertical, prominent ? 8 : 6)
            }.buttonStyle(FieldButton(palette: palette))
                .accessibilityLabel("\(field.rawValue), \(spoken(minutes))")
                .accessibilityHint("Opens a time editor")
                .popover(isPresented: Binding(get: { editingTime == field }, set: { if !$0 { editingTime = nil } })) { timeEditor(field) }
                .help(field.note)
        }.padding(.vertical, prominent ? 12 : 8)
    }
    /// Shared shell for the three popover editors: title, content, note, Done on Return.
    func editor<Content: View>(_ title: String, done: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: Scale.body, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
            HStack { Spacer(); Button("Done", action: done).buttonStyle(QuietButton(palette: palette, color: accent)).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 300)
    }
    func note(_ text: String) -> some View { Text(text).font(.system(size: Scale.caption)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
    func dateBinding(_ field: TimeField) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: binding(field).wrappedValue / 60, minute: binding(field).wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { let parts = Calendar.current.dateComponents([.hour, .minute], from: $0); binding(field).wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) })
    }
    func timeEditor(_ field: TimeField) -> some View {
        editor(field.rawValue, done: { editingTime = nil }) {
            DatePicker(field.rawValue, selection: dateBinding(field), displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField).labelsHidden().accessibilityLabel(field.rawValue)
            note(field.note)
        }
    }
    var routeEditor: some View {
        editor("Your route", done: { editingRoute = false }) {
            input("From", value: $model.origin).focused($routeFocus, equals: .from)
            input("To", value: $model.destination).focused($routeFocus, equals: .to)
            note("These names label a sample journey. Location lookup is not connected.")
        }.defaultFocus($routeFocus, .from)
    }
    var preferences: some View {
        editor("Journey preferences", done: { editingPreferences = nil }) {
            Stepper(model.packing == 0 ? "No packing time" : "\(model.packing) min to pack up", value: $model.packing, in: 0...30, step: 5)
                .accessibilityValue(model.packing == 0 ? "none" : "\(model.packing) minutes")
            note("The wrap-up cue comes this many minutes before departure.")
            Divider()
            Text("Arrival buffer: 10 minutes").font(.system(size: Scale.text, weight: .medium))
            note("Fixed for this prototype. Window plans to arrive before your home-by time, with this buffer.")
        }
    }
    func preferencesShown(_ anchor: PreferencesAnchor) -> Binding<Bool> {
        Binding(get: { editingPreferences == anchor }, set: { if !$0 { editingPreferences = nil } })
    }
    func input(_ label: String, value: Binding<String>) -> some View {
        HStack { Text(label).frame(width: 40, alignment: .leading).foregroundStyle(muted); TextField(label, text: value).textFieldStyle(.roundedBorder).accessibilityLabel(label) }.font(.system(size: Scale.text))
    }
    var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "mappin").foregroundStyle(accent).accessibilityHidden(true)
                Text("\(model.origin) → \(model.destination)").lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("Route: \(model.origin) to \(model.destination)")
                Spacer()
                Button("Edit") { editingRoute = true }.buttonStyle(QuietButton(palette: palette, color: muted)).accessibilityLabel("Edit route")
                    .popover(isPresented: $editingRoute) { routeEditor }
            }.font(.system(size: Scale.body)).padding(.bottom, 12)
            Rectangle().fill(rule).frame(height: 1)
            timeRow(.homeBy, prominent: true)
            Rectangle().fill(rule).frame(height: 1)
            timeRow(.earliest)
            Rectangle().fill(rule).frame(height: 1)
            timeRow(.latest)
            Rectangle().fill(rule).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "briefcase").foregroundStyle(accent).accessibilityHidden(true)
                Text(model.packing == 0 ? "No packing time" : "\(model.packing) min to pack up")
                    .accessibilityLabel(model.packing == 0 ? "No packing time" : "\(model.packing) minutes to pack up")
                Spacer()
                Button("Edit") { editingPreferences = .packing }.buttonStyle(QuietButton(palette: palette, color: muted)).accessibilityLabel("Edit packing time")
                    .popover(isPresented: preferencesShown(.packing)) { preferences }
            }.font(.system(size: Scale.body)).padding(.vertical, 12)
            Rectangle().fill(rule).frame(height: 1)
            if let error = model.validation { Text(error).font(.system(size: Scale.caption)).foregroundStyle(palette.error).fixedSize(horizontal: false, vertical: true).padding(.top, 8).transition(.opacity) }
            Button(model.watchActive ? "Back to my watch" : "Watch my drive home") { model.start() }.buttonStyle(PrimaryButton(palette: palette)).disabled(model.validation != nil).padding(.top, 14)
                .keyboardShortcut(.defaultAction)
            Text("While your Mac is awake and online").font(.system(size: Scale.caption)).foregroundStyle(muted)
                .frame(maxWidth: .infinity).padding(.top, 12)
        }.animation(motion(Motion.value), value: model.validation)
    }
    var alternative: Option? {
        let now = model.immediate
        guard let plan = model.committed, now.departure < plan.departure, model.feasible(now) else { return nil }
        return now
    }
    func benefit(_ option: Option) -> String {
        guard let base = model.base, base.departure != option.departure else { return model.wrapUp ? "Your departure is ready." : "Leaving as soon as you’re ready." }
        let less = base.drive - option.drive, later = option.arrival - base.arrival
        if less <= 0 { return "Waiting no longer reduces driving. Leaving at \(time(base.departure)) would take \(base.drive) min." }
        return "\(less) min less driving than leaving at \(time(base.departure)). Home \(later > 0 ? "\(later) min later" : "no later")."
    }
    func cue(_ option: Option) -> String {
        if model.packing == 0 { return model.wrapUp ? "Leave now" : "Leave on time" }
        return model.wrapUp ? "Wrap up now" : "Wrap up at \(time(option.departure - model.packing))"
    }
    func plan(_ option: Option) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("LEAVE AT").font(.system(size: Scale.label, design: .monospaced)).tracking(2).foregroundStyle(muted)
                HStack(alignment: .bottom, spacing: 6) {
                    ZStack(alignment: .leading) { DotTime(text: time(option.departure), color: accent, height: 56).id(option.departure).transition(.opacity) }
                    if !meridiem(option.departure).isEmpty { Text(meridiem(option.departure)).font(.system(size: Scale.text)).foregroundStyle(accent).padding(.bottom, 4) }
                }
                ZStack(alignment: .leading) {
                    Text(cue(option))
                        .font(.system(size: Scale.title, weight: model.wrapUp ? .semibold : .regular))
                        .foregroundStyle(model.wrapUp ? accent : ink)
                        .id(model.wrapUp)
                        .transition(reduceMotion ? .opacity : .scale(scale: Motion.cueScale, anchor: .leading).combined(with: .opacity))
                }
                Text("\(option.drive) min driving · Home around \(time(option.arrival))").font(.system(size: Scale.text)).foregroundStyle(muted).contentTransition(.opacity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Leave at \(spoken(option.departure)). \(cue(option)). \(option.drive) minutes driving, home around \(time(option.arrival)).")
            Text(benefit(option)).font(.system(size: Scale.text)).fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
        }.animation(motion(Motion.value), value: option.departure).animation(motion(Motion.value), value: model.wrapUp)
    }
    var limits: some View {
        let text = "Leave by \(time(model.latest)) · Home by \(time(model.homeBy))"
        return Text(text).font(.system(size: Scale.caption)).foregroundStyle(muted).contentTransition(.opacity).accessibilityLabel(spokenLine(text))
    }
    func action(_ title: String, _ handler: @escaping () -> Void) -> some View { Button(title, action: handler).buttonStyle(QuietButton(palette: palette)) }
    func leave() { model.finish("You’re on your way.", "Departure confirmed. The watch has ended.", icon: "car") }
    func stop() { model.finish("Watch stopped.", "No alerts remain. Start another watch when you’re ready.", icon: "stop.circle") }
    var watching: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topLeading) {
                if model.stale {
                    VStack(alignment: .leading, spacing: 16) {
                        exception("Your departure is unconfirmed.", detail: "\(model.lastCheck.map { "Last check \(time($0))." } ?? "Nothing checked yet.") Watching pauses when the Mac sleeps or loses its connection.", icon: "wifi.slash")
                        if let previous = model.committed {
                            Text("Previous plan, unconfirmed: leave at \(time(previous.departure)), home around \(time(previous.arrival)).").font(.system(size: Scale.text)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Try again") { model.scenario = .normal; model.refresh() }.buttonStyle(PrimaryButton(palette: palette)).keyboardShortcut(.defaultAction)
                        HStack {
                            if model.wrapUp { action("I’m leaving") { leave() }; Spacer() }
                            action("Stop watching") { stop() }
                        }
                    }.transition(screenTransition)
                } else if let option = model.committed, !model.risk {
                    VStack(alignment: .leading, spacing: 16) {
                        plan(option)
                        Rectangle().fill(rule).frame(height: 1)
                        limits
                        if model.wrapUp {
                            HStack {
                                action("I’m leaving") { leave() }
                                Spacer()
                                action("I need five minutes") { model.delay() }.disabled(!model.canDelay)
                                    .help(model.canDelay ? "Move the departure five minutes later" : "No later departure fits your limits")
                                Spacer()
                                action("Stop watching") { stop() }
                            }
                        } else {
                            HStack {
                                if let sooner = alternative {
                                    action("Leave at \(time(sooner.departure))") { model.choose(sooner.departure) }
                                        .accessibilityLabel("Switch to leaving at \(spoken(sooner.departure))")
                                }
                                Spacer()
                                action("Stop watching") { stop() }
                            }
                        }
                    }.transition(screenTransition)
                } else {
                    let option = model.immediate
                    VStack(alignment: .leading, spacing: 16) {
                        exception(option.arrival > model.homeBy ? "You’d be home after \(time(model.homeBy))." : "Your 10-minute buffer is gone.", detail: "Ready to leave at \(time(option.departure)) after packing. About \(option.drive) min driving, home around \(time(option.arrival)).\(option.departure > model.latest ? " Your latest departure has passed." : "")", icon: "exclamationmark.triangle")
                        Button("Leave as soon as I can") { leave() }.buttonStyle(PrimaryButton(palette: palette))
                        limits
                        HStack { action("Edit my limits") { model.screen = "setup" }; Spacer(); action("Stop watching") { stop() } }
                    }.transition(screenTransition)
                }
            }.animation(motion(Motion.screen), value: model.phase)
            Text("Awake and online only · Simulated").font(.system(size: Scale.caption)).foregroundStyle(muted).accessibilityLabel("Awake and online only, simulated")
        }
    }
    func exception(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.system(size: Scale.display)).foregroundStyle(accent).accessibilityHidden(true)
            Text(title).font(.system(size: Scale.display, weight: .medium)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(detail).font(.system(size: Scale.body)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
    var finished: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: model.endIcon).font(.system(size: 36)).foregroundStyle(accent).accessibilityHidden(true)
            Text(model.endTitle).font(.system(size: Scale.display, weight: .medium)).accessibilityAddTraits(.isHeader)
            Text(model.notice).font(.system(size: Scale.body)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            Button("Plan another departure") { model.reset() }.buttonStyle(PrimaryButton(palette: palette)).keyboardShortcut(.defaultAction)
        }.padding(.vertical, 30)
    }
    var controls: some View {
        HStack {
            Button("Prototype controls") { showingTools = true }
                .buttonStyle(QuietButton(palette: palette, size: Scale.caption, weight: .regular, color: muted))
                .popover(isPresented: $showingTools) { toolsPanel.frame(width: 360) }
            Spacer()
            Picker("Appearance", selection: $model.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }.labelsHidden().frame(width: 100).help("Appearance")
        }.foregroundStyle(muted).padding(.horizontal, 12).padding(.vertical, 8).background(base)
            .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 1) }
    }
    var toolsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMULATED · NO LIVE TRAFFIC OR ALERTS").font(.system(size: Scale.label, weight: .semibold, design: .monospaced)).tracking(2)
                .accessibilityLabel("Simulated, no live traffic or alerts")
            if model.screen == "watch" {
                HStack {
                    Picker("Simulate", selection: $model.scenario) { ForEach(Scenario.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().onChange(of: model.scenario) { model.notice = ""; model.refresh() }
                    Button("+1 min") { model.advance(1) }
                    Button("+5 min") { model.advance(5) }
                    Button("Wrap up") { if let d = model.departure { model.now = max(model.now, d - model.packing); model.refresh() } }.disabled(model.departure == nil || model.stale)
                }.font(.system(size: Scale.caption))
            }
            DisclosureGroup("Inspect simulated state", isExpanded: $model.showInspector) { Text(model.payload).font(.system(size: Scale.label, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: Scale.label))
        }.foregroundStyle(muted).padding(14)
    }
}

/// The four-dot Window mark as a template bitmap for the menu bar.
func markImage(size: CGFloat, dot: CGFloat, color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        color.setFill()
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            NSBezierPath(ovalIn: NSRect(x: CGFloat(x) * (size - dot), y: CGFloat(y) * (size - dot), width: dot, height: dot)).fill()
        }
        return true
    }
}
@MainActor final class WindowMode: ObservableObject { @Published var demo = false }
struct WindowRoot: View {
    @ObservedObject var model: Journey
    @ObservedObject var live: LiveWatch
    @ObservedObject var mode: WindowMode
    var announces = true
    @AppStorage("window.textScale") private var textScale = 1.0
    var body: some View {
        if mode.demo {
            WindowView(model: model, announces: announces).overlay(alignment: .topTrailing) {
                Button("Live watch") { mode.demo = false }.font(.system(size: 11)).padding(6).background(.regularMaterial, in: Capsule()).padding(.top, 6).padding(.trailing, 55)
            }
        } else { LiveWindowView(watch: live, announces: announces).environment(\.windowTextScale, textScale) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = Journey()
    let alerts = LocalWatchAlerts()
    lazy var live = LiveWatch(store: JourneyStore(defaults: .standard), provider: AppleTrafficProvider(), alerts: alerts)
    let mode = WindowMode()
    var subscriptions = Set<AnyCancellable>()
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var item: NSStatusItem!
    var popover = NSPopover()
    var titleSync: AnyCancellable?
    var preview = false
    var onTerminate: (() -> Void)?
    private var buildReceipt: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, let build = Bundle.main.object(forInfoDictionaryKey: "WindowSourceID") as? String {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WindowMac")
            let receipt = directory.appendingPathComponent("running-build.plist")
            let data: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "sourceID": build]
            if let encoded = try? PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0) {
                try? encoded.write(to: receipt, options: .atomic); buildReceipt = receipt
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = mainMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 510), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // the delegate keeps this window; closing must not free it
        window.title = "Window"
        window.contentMinSize = NSSize(width: 420, height: 510)
        window.setFrameAutosaveName("WindowMain")
        window.contentView = NSHostingView(rootView: WindowRoot(model: model, live: live, mode: mode))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let mark = markImage(size: 11, dot: 4.5, color: .black); mark.isTemplate = true
        item.button?.image = mark; item.button?.imagePosition = .imageLeading
        item.button?.title = model.menuTitle; item.button?.target = self; item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("Window")
        for publisher in [model.objectWillChange, live.objectWillChange, mode.objectWillChange] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.syncStatus() }.store(in: &subscriptions)
        }
        alerts.onOpen = { [weak self] in self?.showWindow() }
        live.activateRuntime()
        syncStatus()
        popover.contentSize = NSSize(width: 420, height: 510); popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WindowRoot(model: model, live: live, mode: mode, announces: false))
    }
    /// App, File, and Edit menus: Quit, Close/Minimize, and the standard text actions the route editor needs.
    func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenu()
        let settings = app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Window", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let panel = file.addItem(withTitle: "Show menu bar panel", action: #selector(toggle), keyEquivalent: "p"); panel.target = self
        let show = file.addItem(withTitle: "Show Window", action: #selector(showWindow), keyEquivalent: "0"); show.target = self
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let development = NSMenu(title: "Development")
        let demo = development.addItem(withTitle: "Demo mode", action: #selector(toggleDemo), keyEquivalent: ""); demo.target = self
        for submenu in [app, file, edit, development] { let entry = NSMenuItem(); entry.submenu = submenu; menu.addItem(entry) }
        return menu
    }
    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.title = "Settings"
            settings.contentView = NSHostingView(rootView: LiveSettingsView(watch: live))
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggleDemo() { guard !live.active else { return }; mode.demo.toggle(); showWindow() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDemo) { menuItem.state = mode.demo ? .on : .off; return !live.active }
        return true
    }
    func syncStatus() {
        let title = mode.demo ? model.menuTitle : live.menuTitle
        item.button?.title = title
        item.button?.setAccessibilityLabel(title.isEmpty ? "Window" : "Window: \(title.trimmingCharacters(in: .whitespaces))")
        let appearance = mode.demo ? model.appearance : live.settings.appearance
        popover.appearance = appearance == "System" ? nil : NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua)
        window.title = (mode.demo ? "Window · Demo" : "Window") + (preview ? " · Preview" : "")
    }
    @objc func showWindow() { popover.performClose(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationDidBecomeActive(_ notification: Notification) { live.updateAuthorization(request: false) }
    func applicationWillTerminate(_ notification: Notification) {
        live.shutdown(); onTerminate?()
        if let buildReceipt { try? FileManager.default.removeItem(at: buildReceipt) }
    }
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)   // the popover needs to be key for typing, Return, and Escape
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

/// Renders every state offscreen in both appearances and reports any that need more than 420 × 510 points.
@MainActor func snapshot(into dir: String) {
    let states: [(String, (Journey) -> Void)] = [
        ("setup", { _ in }),
        ("watch", { $0.start() }),
        ("wrapup", { $0.start(); $0.now = 1045; $0.refresh() }),
        ("denied", { $0.start(); $0.scenario = .denied; $0.refresh() }),
        ("offline", { $0.start(); $0.now = 1045; $0.refresh(); $0.scenario = .offline }),
        ("risk", { $0.start(); $0.scenario = .incident; $0.refresh() }),
        ("flat", { $0.start(); $0.scenario = .flat; $0.refresh() }),
        ("missed", { $0.start(); $0.now = 1051; $0.refresh() }),
        ("delayed", { $0.start(); $0.now = 1045; $0.refresh(); $0.delay() }),
        ("finished", { $0.start(); $0.finish("You’re on your way.", "Departure confirmed. The watch has ended.", icon: "car") }),
        ("long-names", { $0.origin = "Riverside Innovation Campus, Building 7"; $0.destination = "Grandmother’s house in Maple Hollow"; $0.start() }),
        ("24-hour", { uses24Hour = true; $0.start() }),
        ("invalid", { $0.latest = 1020 }),
    ]
    var overflow = 0
    for (name, arrange) in states { for mode in ["Light", "Dark"] {
        uses24Hour = false
        let model = Journey(); model.appearance = mode; arrange(model)
        let controller = NSHostingController(rootView: WindowView(model: model))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 510)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: mode == "Dark" ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let needed = NSHostingController(rootView: WindowView(model: model, measuring: true)).sizeThatFits(in: NSSize(width: 420, height: 100000))
        let tag = "\(name)-\(mode.lowercased())"
        if needed.height > 510 { overflow += 1 }
        print("\(tag): needs 420 × \(Int(needed.height))\(needed.height > 510 ? "  OVERFLOW" : "")")
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(tag).png"))
        }
    } }
    uses24Hour = false
    for (name, image) in [("menu-mark", markImage(size: 44, dot: 18, color: .black))] {
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
    }
    print(overflow == 0 ? "PASS: all states fit 420 × 510" : "FAIL: \(overflow) state(s) overflow")
    exit(overflow == 0 ? 0 : 1)
}

@main
struct WindowEntry {
static func main() {
if CommandLine.arguments.contains("--live-test") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        Task { @MainActor in await runLiveWatchTests(); exit(0) }
        app.run()
    }
} else if let i = CommandLine.arguments.firstIndex(of: "--live-snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        Task { @MainActor in await snapshotLive(into: CommandLine.arguments[i + 1]) }
        app.run()
    }
} else if let i = CommandLine.arguments.firstIndex(of: "--live-preview"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let fixture = LiveFixture()
        let delegate = AppDelegate()
        delegate.live = fixture.watch
        delegate.preview = true
        delegate.onTerminate = { fixture.clean() }
        app.delegate = delegate
        Task { @MainActor in
            await arrangeLivePreview(fixture, name: CommandLine.arguments[i + 1], appearance: CommandLine.arguments.contains("--dark") ? "Dark" : "Light")
        }
        withExtendedLifetime((fixture, delegate)) { app.run() }
    }
} else if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated {
        runWatchCoreTests()
        uses24Hour = false
        let m=Journey();m.start();assert(m.departure==1050);assert(m.committed?.arrival==1080);assert(m.baseline==1030)
        for _ in 0..<20 { m.advance(1) };assert(m.departure==1050);assert(m.now==1045);assert(m.wrapUp)   // clock ticks never move a committed plan
        m.advance(5);assert(m.departure==1050);assert(!m.missed)                                          // 5:30 exactly is still the plan
        m.advance(1);assert(m.missed==false);assert(m.departure==nil);assert(m.risk);assert(!m.notice.isEmpty) // passed → replan → nothing fits → risk
        m.advance(1);assert(m.notice.isEmpty);assert(m.status=="Your arrival needs attention")               // the next tick retires the notice
        m.reset();m.start();m.now=1045;m.refresh();m.delay();assert(m.departure==1055);assert(m.latest==1060);assert(m.now==1045)
        assert(!m.canDelay);m.delay();assert(m.departure==1055);assert(m.notice.hasPrefix("No later"))    // limits hold; plan kept; action disabled
        m.reset();m.start();m.choose(1030);m.delay();assert(m.departure==1035)                           // five means five, not a re-optimization
        m.reset();m.start();m.advance(10);m.screen="setup";assert(m.menuTitle==" Leave 5:30");m.start();assert(m.departure==1050);assert(m.baseline==1030);assert(m.notice.isEmpty) // settings keep the plan and the menu title
        m.screen="setup";m.homeBy=1089;m.start();assert(m.departure==nil && m.risk);assert(m.notice.hasPrefix("Limits changed"));m.homeBy=1095 // a deadline before the earliest arrival needs recovery
        m.reset();m.start();m.scenario = .incident;m.refresh();assert(m.risk);assert(m.departure==nil);m.screen="setup";m.start();assert(m.baseline==1030) // risk → edit → back keeps the baseline
        m.reset();m.start();m.finish("x","x",icon:"car");assert(!m.watchActive);m.reset();assert(!m.watchActive)
        m.reset();m.start();m.scenario = .incident;m.refresh();assert(m.risk);assert(m.departure==nil)
        m.reset();m.scenario = .denied;m.now=1070;m.screen="watch";m.refresh();assert(m.risk);assert(m.status=="Your arrival needs attention");assert(m.menuTitle=="") // risk outranks denied; no watch, no menu title
        m.reset();m.start();m.scenario = .offline;let check=m.lastCheck;m.advance(5);assert(m.lastCheck==check);assert(m.stale);assert(m.departure==1050) // offline keeps the plan, unconfirmed
        m.scenario = .normal;m.refresh();assert(!m.stale);assert(m.departure==1050);assert(m.lastCheck==1030)
        m.reset();m.start();m.lastCheck=m.now-11;assert(m.stale)                                          // evidence age, independent of connectivity
        m.reset();m.start();m.choose(1030);assert(m.screen=="watch");assert(m.departure==1030);m.advance(5);assert(m.departure==1030) // earlier choice sticks
        m.reset();m.start();m.scenario = .denied;m.refresh();assert(m.departure==1050);assert(!m.risk);assert(m.phase=="plan")   // denied still has a plan to compare
        m.reset();m.scenario = .flat;m.start();assert(m.departure==1030)
        m.reset();m.start();m.scenario = .flat;m.refresh();assert(m.departure==1030)                     // plan no longer fits home-by → replanned from ready
        m.reset();m.start();m.advance(10);m.screen="setup";m.start();assert(m.now==1035);assert(m.baseline==1030) // editing does not rewind the clock or move the baseline
        m.reset();m.latest=1020;assert(m.validation != nil)
        m.reset();m.latest=1060;m.now=1070;m.screen="watch";m.refresh();assert(m.risk);assert(m.departure==nil)
        m.finish("done","done",icon:"car");assert(m.screen=="finished");assert(m.departure==nil);assert(m.menuTitle=="")
        m.reset();assert(m.lastCheck==nil);m.scenario = .offline;m.start();assert(m.lastCheck==nil);assert(m.departure==nil)
        m.reset();m.origin="  ";assert(m.validation != nil)
        m.reset();m.origin="Office";m.start();assert(m.menuTitle==" Leave 5:30");m.now=1045;m.refresh();assert(m.menuTitle==" Wrap up")
        m.scenario = .incident;m.refresh();assert(m.menuTitle==" Leave now")
        uses24Hour = true;assert(time(1050)=="17:30");assert(meridiem(1050)=="");assert(spoken(545)=="09:05");uses24Hour = false;assert(spoken(1050)=="5:30 PM")
        print("PASS: stable plan through ticks, passed departure, notice retires, fixed-limit delay, canDelay, incident, offline keeps plan, evidence age, earlier choice, denied, risk over denied, no-benefit, edit keeps clock and baseline, invalid setup, expired window, finish, clean reset, offline start, blank place, menu title, 24-hour")
    }
} else if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { _ = NSApplication.shared; snapshot(into: CommandLine.arguments[i + 1]) }
} else {
    MainActor.assumeIsolated {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate
        app.run()
    }
}

}
}

#endif
