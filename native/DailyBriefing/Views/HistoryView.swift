import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query private var rows: [SavedBriefing]
    @Bindable var controller: BriefingController
    @State private var query = ""
    private var sortedRows: [SavedBriefing] { rows.sorted { $0.generatedAt > $1.generatedAt } }
    var body: some View {
        List {
            ForEach(sortedRows) { row in
                if let raw = row.snapshot {
                    let snapshot = controller.visible(raw, historical: true)
                    // Never search the unfiltered stored text: hidden sources must not leak through matches.
                    if query.isEmpty || snapshot.summaryText.localizedCaseInsensitiveContains(query) {
                        NavigationLink { SavedBriefingView(snapshot: raw, controller: controller) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.generatedAt.formatted(date: .complete, time: .shortened)).font(.headline)
                                Text("\(snapshot.sections.count) sections · \(snapshot.pinnedItems.count) pinned").font(.caption).foregroundStyle(.secondary)
                                Text(snapshot.summaryText).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } else if query.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Saved briefing needs recovery", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
                        Text(row.generatedAt.formatted()).font(.caption)
                        Text(row.recoveryReason ?? "The original data is preserved and has not been deleted.").font(.caption).foregroundStyle(.secondary)
                        if row.canRestoreBackup { Button("Restore readable backup") { controller.restore(row) } }
                    }
                }
            }
        }
        .navigationTitle("Briefing history")
        .searchable(text: $query, prompt: "Search enabled sources in saved briefings")
        .overlay { if rows.isEmpty { ContentUnavailableView("Your history starts here", systemImage: "clock", description: Text("Refresh Today to save your first briefing for offline reading.")) } }
    }
}
struct SavedBriefingView: View {
    @State var snapshot: BriefingSnapshot
    @Bindable var controller: BriefingController
    private var visible: BriefingSnapshot { controller.visible(snapshot, historical: true) }
    var body: some View {
        List {
            Section { Text("Saved \(visible.generatedAt.formatted(date: .abbreviated, time: .shortened)). Source timestamps below belong to this saved briefing.").font(.caption).foregroundStyle(.secondary) }
            ForEach(visible.sections) { section in
                Section(section.kind.title) {
                    Text(section.assessed(at: controller.now).message).font(.caption).foregroundStyle(.secondary)
                    ForEach(section.items) { item in
                        ItemRow(item: item, pinned: visible.pinnedItems.contains(item.id))
                            .swipeActions { Button("Pin", systemImage: "pin") {
                                var copy = visible
                                if !copy.pinnedItems.insert(item.id).inserted { copy.pinnedItems.remove(item.id) }
                                controller.update(copy)
                            }.tint(.orange) }
                    }
                    Button(visible.readSections.contains(section.kind) ? "Mark unread" : "Mark read") {
                        var copy = visible
                        if !copy.readSections.insert(section.kind).inserted { copy.readSections.remove(section.kind) }
                        controller.update(copy)
                    }
                }
            }
        }.navigationTitle("Saved briefing").toolbar { ShareLink(item: visible.summaryText) }
    }
}
