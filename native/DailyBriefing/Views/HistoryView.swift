import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \SavedBriefing.generatedAt, order: .reverse) private var rows: [SavedBriefing]
    @Bindable var controller: BriefingController
    @State private var query = ""
    var body: some View {
        List {
            ForEach(rows.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { row in
                if let snapshot = row.snapshot {
                    NavigationLink {
                        SavedBriefingView(snapshot: snapshot, controller: controller)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.generatedAt.formatted(date: .complete, time: .shortened)).font(.headline)
                            Text("\(snapshot.sections.count) sections · \(snapshot.pinnedItems.count) pinned").font(.caption).foregroundStyle(.secondary)
                            Text(row.text).lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Briefing history")
        .searchable(text: $query, prompt: "Search saved briefings")
        .overlay { if rows.isEmpty { ContentUnavailableView("Your history starts here", systemImage: "clock", description: Text("Refresh Today to save your first briefing for offline reading.")) } }
    }
}
struct SavedBriefingView: View {
    @State var snapshot: BriefingSnapshot
    @Bindable var controller: BriefingController
    var body: some View {
        List {
            Section { Text("Saved \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)). Source timestamps below belong to this saved briefing.").font(.caption).foregroundStyle(.secondary) }
            ForEach(snapshot.sections) { section in
                Section(section.kind.title) {
                    Text(section.assessed(at: Date()).message).font(.caption).foregroundStyle(.secondary)
                    ForEach(section.items) { item in
                        ItemRow(item: item, pinned: snapshot.pinnedItems.contains(item.id))
                            .swipeActions { Button("Pin", systemImage: "pin") {
                                if !snapshot.pinnedItems.insert(item.id).inserted { snapshot.pinnedItems.remove(item.id) }
                                controller.update(snapshot)
                            }.tint(.orange) }
                    }
                    Button(snapshot.readSections.contains(section.kind) ? "Mark unread" : "Mark read") {
                        if !snapshot.readSections.insert(section.kind).inserted { snapshot.readSections.remove(section.kind) }
                        controller.update(snapshot)
                    }
                }
            }
        }.navigationTitle("Saved briefing").toolbar { ShareLink(item: snapshot.summaryText) }
    }
}
