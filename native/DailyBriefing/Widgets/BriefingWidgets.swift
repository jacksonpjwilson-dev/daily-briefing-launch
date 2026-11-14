import SwiftUI
import WidgetKit
import ActivityKit

struct BriefingEntry: TimelineEntry {
    let date: Date
    var snapshot: BriefingSnapshot? { SharedSnapshot.read() }
}
struct BriefingTimeline: TimelineProvider {
    func placeholder(in context: Context) -> BriefingEntry { BriefingEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (BriefingEntry) -> Void) { completion(.init(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefingEntry>) -> Void) {
        let now = Date(), snapshot = SharedSnapshot.read()
        // An entry at expiry lets the UI show stale data even without a network refresh.
        let expiries = (snapshot?.sections.compactMap(\.expiresAt) ?? []).filter { $0 > now && $0 < now.addingTimeInterval(3600) }
        let entries = ([now] + expiries).sorted().map { BriefingEntry(date: $0) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
    }
}
struct BriefingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefingEntry
    private var referenceDate: Date { max(entry.date, Date()) }
    private var selected: BriefingSection? { entry.snapshot?.sections.first { $0.kind == SharedSnapshot.selectedSection } }
    private var items: [BriefingItem] {
        guard let selected else { return [] }
        if selected.kind == .schedule { return selected.items.filter { ($0.end ?? $0.date ?? .distantPast) > referenceDate } }
        return selected.items
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack { Image(systemName: selected?.kind.symbol ?? "sun.horizon"); Text(selected?.isFresh(at: referenceDate) == true ? "Ready" : "Open").font(.caption2) }
            case .accessoryInline:
                Text((selected?.isFresh(at: referenceDate) == true ? "" : "Cached · ") + (items.first?.title ?? "Open Daily Briefing"))
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text(items.first?.title ?? "Daily Briefing").font(.headline).lineLimit(1)
                    if let date = items.first?.date, date > referenceDate { Text(date, style: .relative) }
                    else { Text(selected?.isFresh(at: referenceDate) == true ? "Briefing ready" : "Open to refresh").font(.caption) }
                }
            default:
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Label("Daily Briefing", systemImage: "sun.max.fill"); Spacer(); Text(entry.date, style: .date).font(.caption2) }.font(.caption.weight(.bold)).foregroundStyle(.cyan)
                    if let selected {
                        Text(selected.kind.title).font(.headline)
                        if !selected.isFresh(at: referenceDate) { Text("Cached · Open to refresh").font(.caption2).foregroundStyle(.orange) }
                        if items.isEmpty { Text(selected.message.isEmpty ? "No upcoming items." : selected.message).font(.caption) }
                        ForEach(Array(items.prefix(family == .systemSmall ? 1 : family == .systemMedium ? 2 : 4))) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                if let date = item.date { Text(date, style: .time).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        if family == .systemLarge {
                            ForEach((entry.snapshot?.sections ?? []).filter { $0.kind != selected.kind }.prefix(3)) { section in
                                Divider()
                                Label((section.isFresh(at: referenceDate) ? "" : "Cached · ") + (section.items.first?.title ?? section.state.rawValue.capitalized), systemImage: section.kind.symbol).font(.caption).lineLimit(2)
                            }
                        }
                    } else { Text("Open the app to prepare your briefing.").font(.subheadline) }
                    Spacer(minLength: 0)
                    if let generated = entry.snapshot?.generatedAt { Text("Saved \(generated.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .containerBackground(for: .widget) { LinearGradient(colors: [Color(red: 0.06, green: 0.1, blue: 0.16), .black], startPoint: .topLeading, endPoint: .bottomTrailing) }
        .widgetURL(URL(string: "dailybriefing://\(SharedSnapshot.selectedSection.rawValue)"))
    }
}
struct DailyBriefingWidget: Widget {
    let kind = "DailyBriefingWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BriefingTimeline()) { BriefingWidgetView(entry: $0) }
            .configurationDisplayName("Daily Briefing").description("Cached highlights. Choose the highlighted section in the app's Settings.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct ShiftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Label(context.attributes.title, systemImage: "briefcase.fill").font(.headline)
                Text("Shift starts \(context.state.startsAt.formatted(date: .omitted, time: .shortened))")
                Text(timerInterval: Date()...max(Date(), context.state.startsAt), countsDown: true).monospacedDigit()
            }.padding().activityBackgroundTint(.black.opacity(0.9)).activitySystemActionForegroundColor(.cyan)
                .widgetURL(URL(string: "dailybriefing://schedule"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "briefcase.fill").foregroundStyle(.cyan) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.startsAt, style: .time) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text(context.attributes.title).lineLimit(1)
                        Text(timerInterval: Date()...max(Date(), context.state.startsAt), countsDown: true).monospacedDigit()
                    }
                }
            } compactLeading: { Image(systemName: "briefcase.fill").foregroundStyle(.cyan) }
              compactTrailing: { Text(timerInterval: Date()...max(Date(), context.state.startsAt), countsDown: true).monospacedDigit().frame(width: 48) }
              minimal: { Image(systemName: "briefcase.fill") }
            .widgetURL(URL(string: "dailybriefing://schedule")).keylineTint(.cyan)
        }
    }
}
@main struct DailyBriefingWidgets: WidgetBundle {
    var body: some Widget { DailyBriefingWidget(); ShiftLiveActivity() }
}
