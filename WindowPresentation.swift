import SwiftUI
import AppKit

// 2026-11-08, GPT-6: disambiguate the State wrapper from the Xcode 27 State macro.
private typealias PresentationState<Value> = SwiftUI.State<Value>

/// The six approved sizes remain defined in Scale. Supporting text uses the
/// system face; only the small clock label uses monospaced lettering.
enum WindowType {
    enum Role { case display, title, body, text, caption, label }
    static func font(_ role: Role, scale: CGFloat, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch role {
        case .display: size = Scale.display
        case .title: size = Scale.title
        case .body: size = Scale.body
        case .text: size = Scale.text
        case .caption: size = Scale.caption
        case .label: size = Scale.label
        }
        return .system(size: size * WindowTextMetrics.normalized(scale), weight: weight,
                       design: role == .label ? .monospaced : .default)
    }
}

struct WindowReadingContext: DynamicProperty {
    @Environment(\.windowTextScale) private var requestedScale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    var scale: CGFloat { WindowTextMetrics.normalized(requestedScale) }
    var palette: Palette { Palette(dark: scheme == .dark, highContrast: contrast == .increased) }
}

/// Apply at each native presentation boundary. An open editor must follow a
/// change in appearance, including returning to System, without a captured palette.
private struct WindowReadingSurface: ViewModifier {
    let appearance: String
    var solidBackground: Bool
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.windowTextScale) private var requestedScale
    private var forcedScheme: ColorScheme? {
        appearance == "System" ? nil : appearance == "Dark" ? .dark : .light
    }
    func body(content: Content) -> some View {
        let scheme = forcedScheme ?? systemScheme
        let palette = Palette(dark: scheme == .dark, highContrast: contrast == .increased)
        let scale = WindowTextMetrics.normalized(requestedScale)
        content
            .environment(\.colorScheme, scheme)
            .environment(\.windowTextScale, scale)
            .font(WindowType.font(.text, scale: scale))
            .foregroundStyle(palette.ink)
            .tint(palette.accent)
            .background { if solidBackground { palette.base } }
            .preferredColorScheme(forcedScheme)
    }
}
extension View {
    func windowReadingSurface(appearance: String, solidBackground: Bool = true) -> some View {
        #if WINDOW_TARAS_NATIVE
        modifier(WindowReadingSurface(appearance: "Dark", solidBackground: solidBackground))
        #else
        modifier(WindowReadingSurface(appearance: appearance, solidBackground: solidBackground))
        #endif
    }
}

/// Press feedback changes the surface, not text opacity. The older demo styles
/// remain isolated in WindowPrototype; all live secondary actions use this style.
struct WindowSecondaryButton: ButtonStyle {
    let palette: Palette
    var size: CGFloat = Scale.text
    var color: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, palette: palette, size: size, color: color)
    }
    private struct Styled: View {
        let configuration: Configuration
        let palette: Palette
        let size: CGFloat
        let color: Color?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.windowTextScale) private var scale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @PresentationState private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: size * WindowTextMetrics.normalized(scale), weight: .medium))
                .foregroundStyle(hovering && enabled ? palette.accent : color ?? palette.ink)
                .padding(.vertical, 4).frame(minHeight: 24)
                .background(enabled && configuration.isPressed ? palette.fieldHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: Palette.radius))
                .opacity(enabled ? 1 : Palette.disabled)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Palette.radius))
                .onHover { hovering = enabled && $0 }
                .onChange(of: enabled) { _, value in if !value { hovering = false } }
                .onDisappear { hovering = false }
                .animation(reduceMotion ? nil : Motion.press, value: hovering)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}

/// An input boundary must remain distinguishable from its filled surface.
/// Keep the native Button's activation and focus; do not animate its text opacity.
struct WindowFieldButton: ButtonStyle {
    let palette: Palette
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, palette: palette)
    }
    private struct Styled: View {
        let configuration: Configuration
        let palette: Palette
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @PresentationState private var hovering = false
        var body: some View {
            configuration.label
                .background(enabled && (hovering || configuration.isPressed) ? palette.fieldHover : palette.field,
                            in: RoundedRectangle(cornerRadius: Palette.radius))
                .overlay(RoundedRectangle(cornerRadius: Palette.radius)
                    .stroke(hovering && enabled ? palette.accent : palette.ink.opacity(contrast == .increased ? 1 : 0.60)))
                .opacity(enabled ? 1 : Palette.disabled)
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Palette.radius))
                .onHover { hovering = enabled && $0 }
                .onChange(of: enabled) { _, value in if !value { hovering = false } }
                .onDisappear { hovering = false }
                .animation(reduceMotion ? nil : Motion.press, value: hovering)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}


/// Native controls own their material, foreground, pressed state and focus.
/// Do not put a custom glassEffect, opacity or scale animation around them.
/// In particular, inactive/disabled glass must not inherit a hand-picked label
/// color intended for an enabled prominent button on a different material.
struct WindowNativeButton: PrimitiveButtonStyle {
    let palette: Palette
    var prominent = true
    var fillsWidth = true
    @Environment(\.windowTextScale) private var scale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(WindowType.font(prominent ? .body : .text, scale: scale, weight: .medium))
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.vertical, fillsWidth ? 5 : 0)
        }.tint(palette.accent).controlSize(fillsWidth ? .large : .regular)
        if #available(macOS 26, *), !reduceTransparency && contrast != .increased {
            if prominent { button.buttonStyle(.glassProminent) }
            else { button.buttonStyle(.glass) }
        } else {
            if prominent { button.buttonStyle(.borderedProminent) }
            else { button.buttonStyle(.bordered) }
        }
    }
}

/// A small adjacent action group, not a container spanning the whole window.
/// Zero blending distance keeps Cancel and Done visually distinct at rest.
struct WindowGlassActions<Content: View>: View {
    let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if #available(macOS 26, *), !reduceTransparency && contrast != .increased {
            GlassEffectContainer(spacing: 0) { content }
        } else { content }
    }
}

/// The panel's capsule, for the deeper windows: mono uppercase, 1 px ring.
/// Primary is the panel's own WATCH 17:30 capsule (TarasButtonStyle(prominent: true)):
/// the same 1 px ring as EDIT over a faint white wash (5.5 %, 14 % pressed), light text,
/// medium weight. The ring brightens on hover; the fill does not. Secondary is the
/// panel's bare ring (EDIT, +5 MIN), used for Cancel and lesser actions. Quiet is text only.
/// Drawn by hand, so it reads the same in an inactive window, under a sheet and in
/// offscreen captures, where glass does not.
struct TarasCapsuleButton: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let palette: Palette
    var kind: Kind = .primary
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, palette: palette, kind: kind)
    }
    private struct Styled: View {
        let configuration: Configuration
        let palette: Palette
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.windowTextScale) private var requestedScale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @PresentationState private var hovering = false
        private var fill: Color {
            switch kind {
            case .primary:
                guard enabled else { return .clear }
                return palette.ink.opacity(configuration.isPressed ? 0.14 : 0.055)
            case .secondary, .quiet:
                guard enabled else { return .clear }
                return palette.ink.opacity(configuration.isPressed ? 0.14 : hovering ? 0.055 : 0)
            }
        }
        private var ring: Color {
            switch kind {
            case .quiet: return .clear
            case .primary, .secondary: return enabled ? (hovering ? palette.capsuleRingHover : palette.capsuleRing) : palette.rule
            }
        }
        private var ink: Color {
            guard enabled else { return palette.muted.opacity(0.7) }
            switch kind {
            case .primary, .secondary: return palette.ink
            case .quiet: return hovering ? palette.ink : palette.muted
            }
        }
        var body: some View {
            let scale = WindowTextMetrics.normalized(requestedScale)
            configuration.label
                .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                .tracking(0.55 * scale)
                .textCase(.uppercase).lineLimit(1).fixedSize()
                .foregroundStyle(ink)
                // The panel's capsule pads its label 14 pt a side.
                .padding(.horizontal, (kind == .quiet ? 10 : 14) * scale)
                .frame(height: WindowControlMetrics.height(scale))
                .background(TarasCapsuleRing().fill(fill))
                .overlay(TarasCapsuleRing().stroke(ring, lineWidth: 1))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .fixedSize()
                .onHover { hovering = enabled && $0 }
                .onChange(of: enabled) { _, value in if !value { hovering = false } }
                .onDisappear { hovering = false }
                .animation(reduceMotion ? nil : Motion.press, value: hovering)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}

/// The capsule's own outline, half a pixel inside its bounds so a 1 px stroke lands
/// exactly on the edge. Built from lines and arcs on purpose: a Capsule or a rounded
/// rectangle at half its height can be drawn as a bordered layer, and the offscreen
/// capture (cacheDisplay) then shows a stray vertical bar at each end (f2f8049, 744a83b).
struct TarasCapsuleRing: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        guard r.width > 0, r.height > 0 else { return Path() }
        let radius = min(r.width, r.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(center: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addArc(center: CGPoint(x: r.minX + radius, y: r.midY), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// One height for capsules, fields and steppers, so a row of them lines up.
enum WindowControlMetrics {
    static func height(_ scale: CGFloat) -> CGFloat { 32 * WindowTextMetrics.normalized(scale) }
    static let gap: CGFloat = 4
}

/// The panel's caption: mono caps at the label size, 0.4 tracking, secondary grey.
/// Section and field names only; values and sentences stay in the system face.
struct WindowCaption: View {
    let text: String
    var reading = WindowReadingContext()
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: Scale.label * reading.scale, weight: .medium, design: .monospaced))
            .tracking(0.4 * reading.scale)
            .foregroundStyle(reading.palette.muted).lineLimit(1).fixedSize()
            .accessibilityLabel(text).accessibilityAddTraits(.isHeader)
    }
}

/// A few choices as parts of one capsule, in the sheets' type so it scales with the
/// reading size (a system popup keeps its own small font).
struct WindowCapsuleChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]
    var reading = WindowReadingContext()
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: Scale.text * scale, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.ink : palette.muted).lineLimit(1).fixedSize()
                        .padding(.horizontal, 10 * scale).frame(minHeight: 26 * scale)
                        .background(TarasCapsuleRing().fill(selected ? palette.ink.opacity(0.14) : Color.clear))
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(TarasCapsuleRing().fill(palette.field))
        .overlay(TarasCapsuleRing().stroke(palette.capsuleRing, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// A sheet's text entry at the capsule's height with a 1 px border. Focus and selection
/// are the system's: the keyboard focus ring colour and the user's selection highlight,
/// not the app's orange (which stays the accent everywhere else). On a card the field
/// takes the card's own fill.
struct WindowFieldChrome: ViewModifier {
    let focused: Bool
    var onCard = false
    var reading = WindowReadingContext()
    func body(content: Content) -> some View {
        let scale = reading.scale
        let palette = reading.palette
        let radius = 6 * scale
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        content
            .textFieldStyle(.plain)
            // The system accent drives the insertion point and selectedTextBackgroundColor.
            .tint(Color(nsColor: .controlAccentColor))
            .padding(.horizontal, 10 * scale)
            .frame(height: WindowControlMetrics.height(scale))
            .background(onCard ? Color.clear : palette.field, in: shape)
            .overlay(shape.strokeBorder(palette.capsuleRing, lineWidth: 1))
            // The native ring: system colour, drawn just outside the border as macOS does.
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius + 3, style: .circular)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(-3).allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
    }
}
extension View {
    func windowFieldChrome(focused: Bool, onCard: Bool = false) -> some View {
        modifier(WindowFieldChrome(focused: focused, onCard: onCard))
    }
}

/// Up and down arrows at the field's height, meant to sit 4 pt from it. Steps by five;
/// adjustable with VoiceOver and the scroll wheel like the system stepper it replaces.
struct WindowStepper: View {
    @Binding var value: Int
    let bounds: ClosedRange<Int>
    let label: String
    var reading = WindowReadingContext()
    @Environment(\.isEnabled) private var enabled
    private func step(_ steps: Int) {
        value = TimeScrollAccumulator.adjusted(value, steps: steps, bounds: bounds)
    }
    var body: some View {
        let scale = reading.scale
        let palette = reading.palette
        let shape = RoundedRectangle(cornerRadius: 6 * scale, style: .circular)
        VStack(spacing: 0) {
            arrow("chevron.up", steps: 1, scale: scale, palette: palette)
            Rectangle().fill(palette.rule).frame(height: 1)
            arrow("chevron.down", steps: -1, scale: scale, palette: palette)
        }
        .frame(width: 22 * scale, height: WindowControlMetrics.height(scale))
        .background(palette.field, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.capsuleRing, lineWidth: 1))
        .opacity(enabled ? 1 : Palette.disabled)
        .modifier(ScrollAdjustableTime(value: $value, bounds: bounds))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }
    private func arrow(_ symbol: String, steps: Int, scale: CGFloat, palette: Palette) -> some View {
        Button { step(steps) } label: {
            Image(systemName: symbol).font(.system(size: 8 * scale, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(palette.muted)
        .focusable(false)
    }
}

extension View {
    /// Deeper-window actions: the panel's capsule in the shipped app; native glass in the prototype.
    @ViewBuilder func windowActionStyle(_ palette: Palette, kind: TarasCapsuleButton.Kind = .primary) -> some View {
        #if WINDOW_TARAS_NATIVE
        buttonStyle(TarasCapsuleButton(palette: palette, kind: kind))
        #else
        buttonStyle(WindowNativeButton(palette: palette, prominent: kind == .primary, fillsWidth: false))
        #endif
    }
}

struct WindowDialogActions: View {
    let palette: Palette
    var confirmTitle = "Done"
    var canConfirm = true
    var usesReturn = true
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        #if WINDOW_TARAS_NATIVE
        // The shipped app: Cancel is a plain capsule on Esc; the primary is the
        // panel's WATCH capsule, the default on Return.
        HStack(spacing: 8) {
            Spacer(minLength: 8)
            Button(role: .cancel, action: cancel) { Text("Cancel") }
                .buttonStyle(TarasCapsuleButton(palette: palette, kind: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: confirm)
                .buttonStyle(TarasCapsuleButton(palette: palette))
                .disabled(!canConfirm)
                .keyboardShortcut(usesReturn ? KeyboardShortcut.defaultAction : nil)
        }
        #else
        HStack {
            Spacer(minLength: 8)
            WindowGlassActions {
                HStack(spacing: 8) {
                    Button(role: .cancel, action: cancel) { Text("Cancel") }
                        .buttonStyle(WindowNativeButton(palette: palette, prominent: false, fillsWidth: false))
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: confirm)
                        .buttonStyle(WindowNativeButton(palette: palette, fillsWidth: false))
                        .disabled(!canConfirm)
                        .keyboardShortcut(usesReturn ? KeyboardShortcut.defaultAction : nil)
                }
            }
        }
        #endif
    }
}

/// Full-row interaction feedback without adding glass to information or results.
struct WindowRowButton: ButtonStyle {
    let palette: Palette
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, palette: palette, selected: selected)
    }
    private struct Row: View {
        let configuration: Configuration
        let palette: Palette
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @PresentationState private var hovering = false
        var body: some View {
            configuration.label
                .frame(minHeight: 28)
                .background(selected || (enabled && (hovering || configuration.isPressed)) ? palette.fieldHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: Palette.radius))
                .overlay(RoundedRectangle(cornerRadius: Palette.radius)
                    .stroke(selected ? palette.accent : Color.clear))
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Palette.radius))
                .opacity(enabled ? 1 : Palette.disabled)
                .onHover { hovering = enabled && $0 }
                .onChange(of: enabled) { _, value in if !value { hovering = false } }
                .onDisappear { hovering = false }
                .animation(reduceMotion ? nil : Motion.press, value: hovering)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
        }
    }
}

/// Fixture-only native material proof used by the isolated presentation runner.
/// Bitmap captures do not establish compositor, pointer or focus behavior.
struct WindowControlReview: View {
    var reading = WindowReadingContext()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Native action states").font(WindowType.font(.title, scale: reading.scale, weight: .semibold))
            Button("Use this departure") {}.buttonStyle(WindowNativeButton(palette: reading.palette))
            Button("Checking…") {}.buttonStyle(WindowNativeButton(palette: reading.palette)).disabled(true)
            WindowDialogActions(palette: reading.palette, cancel: {}, confirm: {})
            WindowDialogActions(palette: reading.palette, canConfirm: false, cancel: {}, confirm: {})
            Button("Selected place") {}.buttonStyle(WindowRowButton(palette: reading.palette, selected: true))
            Text("Inspect active/inactive windows, Reduce Transparency, Increase Contrast and keyboard focus in a live preview.")
                .font(WindowType.font(.caption, scale: reading.scale)).foregroundStyle(reading.palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(20)
    }
}

// MARK: - The panel's row grammar for the deeper windows

/// A row's status line: the panel's mono caps, wrapping rather than cutting off.
/// Unlike WindowCaption it names a fact, not a section, so it is not a header.
struct WindowKicker: View {
    let text: String
    var reading = WindowReadingContext()
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: Scale.label * reading.scale, weight: .medium, design: .monospaced)).tracking(0.4 * reading.scale)
            .foregroundStyle(reading.palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One fact as the panel sets it: a mono kicker over a name, the value right-aligned
/// in the panel's digits. Stack in a VStack(spacing: 0) and finish with windowBox.
struct WindowFactRow: View {
    let kicker: String
    let name: String
    let value: String
    var dim = false
    var first = false
    var reading = WindowReadingContext()
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        VStack(alignment: .leading, spacing: 4 * scale) {
            WindowKicker(kicker)
            HStack(spacing: 10) {
                Text(name).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(value).fontWeight(.medium).monospacedDigit().fixedSize()
                    .foregroundStyle(dim ? palette.muted : palette.ink)
            }
            .font(.system(size: Scale.body * scale))
        }
        .padding(.horizontal, 12).padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if !first { Rectangle().fill(palette.rule).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The recovery window's box: rows on the panel's fill inside one hairline.
    func windowBox(_ palette: Palette) -> some View {
        background(palette.field)
            .clipShape(RoundedRectangle(cornerRadius: Palette.radius))
            .overlay(RoundedRectangle(cornerRadius: Palette.radius).stroke(palette.rule).allowsHitTesting(false))
    }
}

/// One stepper arrow: muted at rest, full ink on hover, the row's hover fill when pressed.
struct WindowStepperArrowStyle: ButtonStyle {
    let palette: Palette
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, palette: palette) }
    private struct Styled: View {
        let configuration: Configuration
        let palette: Palette
        @PresentationState private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? palette.ink : palette.muted)
                .background(configuration.isPressed ? palette.fieldHover : Color.clear)
                .onHover { hovering = $0 }
        }
    }
}

/// A time or minutes field with its stepper built in, set as one of the panel's value
/// rows: full width on the row fill, the value left-aligned in the panel's digits with
/// an optional unit after it, and the up and down arrows as a slim trailing column
/// behind a hairline. Type, press an arrow, use the arrow keys or scroll over the
/// arrows; everything scales with the text size.
struct WindowStepperField: View {
    @Binding var text: String
    let placeholder: String
    var unit: String? = nil
    let label: String
    let stepLabel: String
    let canStep: Bool
    @Binding var stepValue: Int
    let bounds: ClosedRange<Int>
    var focus: FocusState<Bool>.Binding
    var reading = WindowReadingContext()
    @Environment(\.displayScale) private var displayScale
    private func step(_ steps: Int) {
        guard canStep else { return }
        stepValue = TimeScrollAccumulator.adjusted(stepValue, steps: steps, bounds: bounds)
    }
    /// Wide enough for the longest value (17:30 or 30), so the unit sits right after it.
    private func valueWidth(_ size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let sample = unit == nil ? "88:88" : "88"
        return ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 4
    }
    var body: some View {
        let palette = reading.palette
        let scale = reading.scale
        let focused = focus.wrappedValue
        let hairline = 1 / max(displayScale, 1)
        let shape = RoundedRectangle(cornerRadius: Palette.radius, style: .circular)
        let size = Scale.title * scale
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain).focusEffectDisabled()
                        .tint(Color(nsColor: .controlAccentColor)) // system insertion point and selection
                        .font(.system(size: size, weight: .medium).monospacedDigit())
                        .multilineTextAlignment(.leading)
                        .frame(width: valueWidth(size))
                        .focused(focus)
                        .accessibilityLabel(label)
                        .onMoveCommand { direction in
                            if direction == .up { step(1) } else if direction == .down { step(-1) }
                        }
                    if let unit {
                        Text(unit).font(.system(size: Scale.body * scale)).foregroundStyle(palette.muted)
                            .fixedSize().accessibilityHidden(true)
                    }
                }
                // The rest of the value area takes the click too, not only the digits.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { focus.wrappedValue = true }
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(palette.rule).frame(width: hairline).padding(.vertical, 7 * scale)
            // Each arrow is a full half of the field: 32 × 20 pt at Standard, larger than
            // the system stepper's arrows (about 13 × 11 pt).
            VStack(spacing: 0) {
                arrow("chevron.up", steps: 1, scale: scale, palette: palette)
                arrow("chevron.down", steps: -1, scale: scale, palette: palette)
            }
            .frame(width: 32 * scale)
            .opacity(canStep ? 1 : Palette.disabled)
            .modifier(ScrollAdjustableTime(value: $stepValue, bounds: bounds))
            .disabled(!canStep)
            .accessibilityElement()
            .accessibilityLabel(stepLabel)
            .accessibilityValue(text)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
        }
        // Wide enough for the value and its unit; the arrows stay close to the number.
        .frame(width: 168 * scale, height: 40 * scale)
        .background(palette.field, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.capsuleRing, lineWidth: 1).allowsHitTesting(false))
        // The system's focus ring colour, just outside the border; orange stays the accent elsewhere.
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: Palette.radius + 3, style: .circular)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-3).allowsHitTesting(false)
            }
        }
    }
    private func arrow(_ symbol: String, steps: Int, scale: CGFloat, palette: Palette) -> some View {
        Button { step(steps) } label: {
            Image(systemName: symbol).font(.system(size: 12 * scale, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(WindowStepperArrowStyle(palette: palette))
        .focusable(false)
    }
}
