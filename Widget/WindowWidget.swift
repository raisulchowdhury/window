import SwiftUI
import WidgetKit
import WindowCore

extension PlanWidgetEntry: @retroactive TimelineEntry {}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlanWidgetEntry {
        PlanWidgetFixtures.all.first { $0.name == "wrap-up" }!.entry
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : PlanWidgetEntry(date: .now, snapshot: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanWidgetEntry>) -> Void) {
        completion(Timeline(entries: PlanWidgetTimeline.entries(snapshot: WidgetSnapshot.read(), now: .now), policy: .never))
    }
}

@main
struct WindowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: SnapshotProvider()) { entry in
            WindowWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { WidgetView.background }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Window")
        .description("Your departure, wrap-up time, drive and estimated arrival.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WindowWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlanWidgetEntry
    var body: some View {
        let model = PlanWidgetModel(entry: entry)
        WidgetView(model: model, small: family == .systemSmall)
            .widgetURL(URL(string: model.alertsOff ? "window://alerts" : "window://panel"))
    }
}

// PreviewProvider avoids the preview macro subprocess, which cannot run in the build sandbox.
struct WidgetPreviews: PreviewProvider {
    static var previews: some View {
        ForEach(PlanWidgetFixtures.states, id: \.self) { name in
            let entry = PlanWidgetFixtures.all.first { $0.name == name }!.entry
            Group {
                WidgetView(model: PlanWidgetModel(entry: entry, calendar: PlanWidgetFixtures.calendar), small: true)
                    .containerBackground(for: .widget) { WidgetView.background }
                    .previewContext(WidgetPreviewContext(family: .systemSmall))
                    .previewDisplayName("Small · " + name)
                WidgetView(model: PlanWidgetModel(entry: entry, calendar: PlanWidgetFixtures.calendar), small: false)
                    .containerBackground(for: .widget) { WidgetView.background }
                    .previewContext(WidgetPreviewContext(family: .systemMedium))
                    .previewDisplayName("Medium · " + name)
            }
        }
    }
}
