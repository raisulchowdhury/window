import SwiftUI
import WidgetKit
import WindowCore

struct WidgetView: View {
    let model: PlanWidgetModel
    let small: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let background = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    private let text = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
    private var labelColor: Color { gray(contrast == .increased ? 190 : 161, blue: contrast == .increased ? 195 : 167) }
    private var valueColor: Color { model.dim ? gray(contrast == .increased ? 174 : 148) : text }

    var body: some View {
        GeometryReader { geometry in
            if model.state == .stale { expiredBody }
            else if small { smallBody(size: geometry.size) }
            else { mediumBody(size: geometry.size) }
        }
        .foregroundStyle(text)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(labelColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var expiredBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            label(model.phaseWord)
            label(model.headerLeft)
            Spacer(minLength: 0)
            Text("Open Window")
                .font(.system(size: 16, weight: .medium))
            label("CHECK TIMES AGAIN")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
    }

    private func phaseLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            if model.phaseWord == "ALERTS OFF" {
                Image(systemName: "bell.slash").font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced))
            } else {
                label(title)
                statusGlyph(model.phaseGlyph)
            }
        }.foregroundStyle(renderingMode == .fullColor ? orange : text)
    }

    private var alertSettingsLabel: some View {
        HStack(spacing: 5) {
            Text("Open alert settings")
            Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true)
        }.font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).frame(height: 20)
            .background(text.opacity(0.09), in: Capsule())
            .overlay { Capsule().strokeBorder(text.opacity(0.3)) }
    }

    private func smallBody(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            label(model.smallHeader).frame(width: size.width - 28, alignment: .leading).offset(x: 14, y: 14)
            phaseLabel(model.phaseWord)
            .frame(width: size.width - 28, alignment: .leading).offset(x: 14, y: 30)
            if model.state == .noPlan {
                noPlanGlyph.frame(width: 40, height: 40).offset(x: 14, y: 48)
            } else {
                Text(model.departure)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .font(.system(size: 36, weight: .medium)).monospacedDigit().tracking(-0.72)
                    .foregroundStyle(valueColor)
                    .frame(height: 40).offset(x: 14, y: 48)
                miniRuler(width: size.width - 28, height: 30)
                    .offset(x: 14, y: size.height - (model.alertsOff ? 75 : 64))
                label(model.smallFooter).minimumScaleFactor(0.8).allowsTightening(true).frame(width: size.width - 28, alignment: .leading)
                    .offset(x: 14, y: size.height - (model.alertsOff ? 42 : 26))
                if model.alertsOff { alertSettingsLabel.offset(x: 14, y: size.height - 28) }
            }
        }
    }

    private func mediumBody(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                label(model.mediumHeaderLeft).layoutPriority(-1)
                Spacer(minLength: 0)
                phaseLabel(model.mediumHeaderRight).fixedSize()
            }.frame(width: size.width - 28).offset(x: 14, y: 14)
            if model.state == .noPlan {
                noPlanGlyph.frame(width: 40, height: 40).offset(x: 14, y: 48)
            } else {
                miniRuler(width: size.width - 28, height: 34).offset(x: 14, y: 34)
                Rectangle().fill(gray(contrast == .increased ? 72 : 46))
                    .frame(width: size.width - 28, height: 1).offset(x: 14, y: 80)
                let columnWidth = (size.width - 44) / 3
                HStack(alignment: .top, spacing: 8) {
                    column(label: model.leaveLabel, value: model.departure, width: columnWidth)
                    column(label: model.wrapLabel, value: model.wrapUp, width: columnWidth)
                    column(label: "ARRIVAL · \(model.driveMinutes)M DRIVE", value: model.arrival, width: columnWidth)
                }.offset(x: 14, y: 91)
                if model.alertsOff {
                    alertSettingsLabel.offset(x: 14, y: size.height - 28)
                } else if model.dim && model.state != .suggested {
                    label(model.smallFooter).offset(x: 14, y: size.height - 28)
                }
            }
        }
    }

    private func column(label title: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title).minimumScaleFactor(0.8).frame(width: width, height: 12, alignment: .leading)
            Text(value).contentTransition(reduceMotion ? .opacity : .numericText()).font(.system(size: 26, weight: .medium)).monospacedDigit()
                .foregroundStyle(valueColor).frame(height: 32)
        }.frame(width: width, alignment: .leading).clipped()
    }

    @ViewBuilder
    private func statusGlyph(_ glyph: RulerModel.Glyph) -> some View {
        switch glyph {
        case .orange, .green:
            Circle().fill(renderingMode == .fullColor ? (glyph == .green ? Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255) : orange) : text)
                .frame(width: 6, height: 6).widgetAccentable().accessibilityHidden(true)
        case .pause:
            Image(systemName: "pause.fill").font(.system(size: 8)).foregroundStyle(labelColor).accessibilityHidden(true)
        case .cross:
            Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(labelColor).accessibilityHidden(true)
        case .hour:
            Image(systemName: "hourglass").font(.system(size: 8)).foregroundStyle(labelColor).accessibilityHidden(true)
        default: EmptyView()
        }
    }

    private var noPlanGlyph: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 0.7)
                    .fill(labelColor).frame(width: 2, height: index == 2 ? 28 : 12)
            }
        }.accessibilityHidden(true)
    }

    private func miniRuler(width: Double, height: Double) -> some View {
        ZStack(alignment: .topLeading) {
            if let rulerModel = model.panel?.model, let sample = model.selectedSample {
                let ruler = rulerModel.miniRuler(width: width, height: height, small: small, center: sample.departure, dim: model.dim)
                Canvas { context, _ in
                    for tick in ruler.ticks {
                        let h = height * (tick.isMajor ? 0.45 : 0.22)
                        let color = gray(contrast == .increased ? 108 : tick.isMajor ? 112 : 74,
                                         blue: contrast == .increased ? 113 : tick.isMajor ? 118 : 79)
                        context.fill(Path(CGRect(x: tick.x - 0.5, y: height - h, width: 1, height: h)),
                                     with: .color(color.opacity(tick.dim ? 0.35 : 1)))
                    }
                    for bar in ruler.bars {
                        context.fill(Path(CGRect(x: bar.x - 1, y: height - bar.height, width: 2, height: bar.height)),
                                     with: .color(text.opacity(bar.opacity)))
                    }
                }
                Rectangle().fill(renderingMode == .fullColor ? orange : text)
                    .frame(width: 2, height: height * 0.42)
                    .offset(x: ruler.cursorX - 1).widgetAccentable()
            }
        }.frame(width: width, height: height).clipped().contentTransition(.identity)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }

    private var orange: Color { Color(red: 245 / 255, green: 105 / 255, blue: 43 / 255) }
    private func gray(_ value: Double, blue: Double? = nil) -> Color {
        Color(red: value / 255, green: value / 255, blue: (blue ?? (value + 4)) / 255)
    }
}
