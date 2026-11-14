import SwiftUI
import WidgetKit

struct WatchEntry: TimelineEntry { var date: Date; var snapshot: BriefingSnapshot? { SharedSnapshot.read() } }
struct WatchTimeline: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        completion(.init(entries: [.init(date: Date())], policy: .after(Date().addingTimeInterval(900))))
    }
}
@main struct WatchBriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchBriefing", provider: WatchTimeline()) { entry in
            VStack(alignment: .leading) {
                Label("Daily Briefing", systemImage: "sun.max.fill").font(.caption)
                if let section = entry.snapshot?.sections.first(where: { $0.kind == .schedule }),
                   let next = section.items.first(where: { ($0.date ?? .distantPast) > max(entry.date, Date()) }) {
                    Text(next.title).font(.headline).lineLimit(1)
                    if let date = next.date { Text(date, style: .relative).font(.caption) }
                    if !section.isFresh(at: max(entry.date, Date())) { Text("Cached").font(.caption2) }
                } else { Text("Open iPhone to refresh").font(.caption) }
            }.containerBackground(.blue.gradient, for: .widget)
        }.configurationDisplayName("Next commitment").description("The next commitment saved from your iPhone briefing.")
            .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
