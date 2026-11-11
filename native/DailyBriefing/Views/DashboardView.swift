import SwiftUI
import EventKitUI

struct DashboardView: View {
    @Bindable var controller: BriefingController
    @Bindable var settings: SettingsStore
    @State private var eventToShow: EventSelection?
    @State private var expanded: Set<SectionKind> = []
    @State private var audioSection = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if controller.phase == .loading { ProgressView("Assembling your sources…").frame(maxWidth: .infinity) }
                if let message = controller.errorMessage { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let snapshot = controller.snapshot {
                    if !controller.deliveryErrors.isEmpty {
                        DisclosureGroup("Delivery needs attention") {
                            ForEach(controller.deliveryErrors, id: \.self) { Text($0).font(.caption) }
                        }.font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Label(snapshot.generatedAt.formatted(date: .omitted, time: .shortened), systemImage: "arrow.clockwise")
                        Text("· \(controller.phase == .partial ? "Partial briefing" : "Saved briefing")")
                        Spacer()
                        ShareLink(item: snapshot.summaryText) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share briefing")
                    }.font(.caption).foregroundStyle(.secondary)
                    if !snapshot.changes.isEmpty {
                        DisclosureGroup("Changes since your previous briefing") {
                            ForEach(snapshot.changes, id: \.self) { Text($0).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
                        }.font(.subheadline.weight(.semibold))
                    }
                    audioControls(snapshot)
                    ForEach(snapshot.sections.filter { !settings.value.hiddenSections.contains($0.kind) }) { raw in
                        let section = raw.assessed(at: Date())
                        SectionCard(section: section, expanded: expanded.contains(section.kind),
                            isRead: snapshot.readSections.contains(section.kind), pinned: snapshot.pinnedItems,
                            toggleExpanded: { withAnimation { if !expanded.insert(section.kind).inserted { expanded.remove(section.kind) } } },
                            refresh: { Task { await controller.refresh(only: section.kind) } },
                            markRead: { var copy = snapshot; if !copy.readSections.insert(section.kind).inserted { copy.readSections.remove(section.kind) }; controller.update(copy) },
                            pin: { id in var copy = snapshot; if !copy.pinnedItems.insert(id).inserted { copy.pinnedItems.remove(id) }; controller.update(copy) },
                            openEvent: { item in if let event = controller.calendar.event(id: item.id) { eventToShow = EventSelection(event: event) } },
                            startActivity: { item in Task { do { try await ShiftActivities.start(item) } catch { controller.errorMessage = error.localizedDescription } } })
                    }
                } else if controller.phase != .loading {
                    ContentUnavailableView("Your day, brought together", systemImage: "sun.horizon.fill", description: Text("Choose your calendars in Settings, then refresh to create your first briefing."))
                    Button("Prepare briefing") { Task { await controller.refresh() } }.buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Daily Briefing").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(controller.phase == .loading).accessibilityLabel("Refresh briefing") }
        .refreshable { await controller.refresh() }
        .sheet(item: $eventToShow) { CalendarEventView(event: $0.event) }
        .sheet(item: $controller.route) { kind in
            NavigationStack {
                ScrollView {
                    if let section = controller.snapshot?.sections.first(where: { $0.kind == kind }) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(section.assessed(at: Date()).message).foregroundStyle(.secondary)
                            ForEach(section.items) { item in ItemRow(item: item, pinned: false) }
                        }.padding()
                    } else { ContentUnavailableView("Section unavailable", systemImage: kind.symbol, description: Text("Enable this section in Settings and refresh.")) }
                }.navigationTitle(kind.title)
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            Text("\(greeting),\n\(settings.value.name.isEmpty ? "welcome" : settings.value.name).")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            if let next = controller.upcomingEvents.first(where: { ($0.date ?? .distantPast) > Date() }) {
                Label(next.title, systemImage: next.isShift ? "briefcase.fill" : "calendar").font(.headline)
                if let start = next.date { Text(start, style: .relative).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let shift = controller.upcomingEvents.first(where: { $0.isShift && ($0.date ?? .distantPast) > Date() }), let start = shift.date {
                HStack { Text("Next work shift"); Spacer(); Text(start, style: .timer).monospacedDigit() }.font(.caption)
            }
            if let weather = controller.snapshot?.sections.first(where: { $0.kind == .weather }), weather.isFresh(at: Date()), let first = weather.items.first {
                Label(first.title, systemImage: "cloud.sun.fill").font(.subheadline)
            }
            if let next = controller.snapshot?.nextDelivery { Text("Next briefing reminder \(next.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(LinearGradient(colors: [.cyan.opacity(0.2), .indigo.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
    }
    private var greeting: String { let h = Calendar.current.component(.hour, from: Date()); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }
    private func audioControls(_ snapshot: BriefingSnapshot) -> some View {
        HStack(spacing: 18) {
            Button { audioSection = 0; controller.speech.play(snapshot.sections.map { "\($0.kind.title). \($0.assessed(at: Date()).state.rawValue). " + $0.items.map(\.title).joined(separator: ". ") }.joined(separator: "\n"), preferences: settings.value) } label: { Label("Listen", systemImage: "play.fill") }
            Button { controller.speech.pause() } label: { Image(systemName: "pause.fill") }.accessibilityLabel("Pause speech")
            Button { controller.speech.resume() } label: { Image(systemName: "playpause.fill") }.accessibilityLabel("Resume speech")
            Button {
                guard !snapshot.sections.isEmpty else { return }
                audioSection = (audioSection + 1) % snapshot.sections.count
                let section = snapshot.sections[audioSection]
                controller.speech.play(section.kind.title + ". " + section.items.map(\.title).joined(separator: ". "), preferences: settings.value)
            } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("Next section")
            Button { controller.speech.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Stop speech")
        }.font(.subheadline).buttonStyle(.borderless)
    }
}
struct SectionCard: View {
    let section: BriefingSection
    let expanded: Bool
    let isRead: Bool
    let pinned: Set<String>
    let toggleExpanded: () -> Void
    let refresh: () -> Void
    let markRead: () -> Void
    let pin: (String) -> Void
    let openEvent: (BriefingItem) -> Void
    let startActivity: (BriefingItem) -> Void
    private var visibleItems: [BriefingItem] {
        if expanded { return section.items }
        let first = Array(section.items.prefix(3))
        return first + section.items.dropFirst(3).filter { $0.attributionImageURL != nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(section.kind.title, systemImage: section.kind.symbol).font(.headline)
                Spacer()
                if isRead { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Menu {
                    Button("Refresh section", systemImage: "arrow.clockwise", action: refresh)
                    Button(isRead ? "Mark unread" : "Mark read", systemImage: "checkmark.circle", action: markRead)
                    Button(expanded ? "Collapse" : "Expand", systemImage: "arrow.up.left.and.arrow.down.right", action: toggleExpanded)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("\(section.kind.title) actions")
            }
            HStack {
                Circle().fill(section.state == .ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(section.state.rawValue.capitalized)
                if let fetched = section.fetchedAt { Text("· Refreshed \(fetched.formatted(date: .abbreviated, time: .shortened))") }
            }.font(.caption).foregroundStyle(.secondary)
            if !section.message.isEmpty { Text(section.message).font(.subheadline).foregroundStyle(.secondary) }
            let conflicts = section.kind == .schedule ? BriefingScheduler.conflicts(section.items) : []
            ForEach(visibleItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    ItemRow(item: item, pinned: pinned.contains(item.id))
                    if conflicts.contains(item.id) { Label("Overlapping commitment", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
                .contextMenu {
                    Button(pinned.contains(item.id) ? "Unpin" : "Pin", systemImage: "pin") { pin(item.id) }
                    if section.kind == .schedule && item.source != "Manual schedule" { Button("View calendar event", systemImage: "calendar") { openEvent(item) } }
                    if item.isShift { Button("Start shift countdown", systemImage: "timer") { startActivity(item) } }
                }
                if item.id != visibleItems.last?.id { Divider() }
            }
            if section.items.count > 3 { Button(expanded ? "Show less" : "Show all \(section.items.count)", action: toggleExpanded).font(.caption.weight(.semibold)) }
        }.padding(20).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}
struct ItemRow: View {
    let item: BriefingItem
    let pinned: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let imageURL = item.attributionImageURL {
                AsyncImage(url: imageURL) { image in image.resizable().scaledToFit() } placeholder: { Text("Apple Weather").foregroundStyle(.black) }
                    .frame(width: 130, height: 24).padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Apple Weather")
            }
            HStack(alignment: .top) {
                Text(item.title).font(.subheadline.weight(.semibold))
                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
            }
            if !item.detail.isEmpty { Text(item.detail).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Text(item.source)
                if let date = item.date { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                if let end = item.end { Text("– \(end.formatted(date: .omitted, time: .shortened))") }
            }.font(.caption2).foregroundStyle(.secondary)
            if let url = item.url, url.scheme == "https" { Link("Open source", destination: url).font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct EventSelection: Identifiable { let id = UUID(); let event: EKEvent }
private struct CalendarEventView: UIViewControllerRepresentable {
    let event: EKEvent
    func makeUIViewController(context: Context) -> UINavigationController {
        let view = EKEventViewController(); view.event = event; view.allowsEditing = false; view.allowsCalendarPreview = false
        return UINavigationController(rootViewController: view)
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
