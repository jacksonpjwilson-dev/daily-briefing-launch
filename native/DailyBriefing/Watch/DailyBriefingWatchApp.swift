import Observation
import SwiftUI
import WatchConnectivity
import WidgetKit

@MainActor @Observable final class WatchSnapshotStore: NSObject, WCSessionDelegate {
    var snapshot: BriefingSnapshot?
    override init() {
        snapshot = UserDefaults.standard.data(forKey: "watch.snapshot").flatMap { try? JSONDecoder().decode(BriefingSnapshot.self, from: $0) }
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let data = session.receivedApplicationContext["snapshot"] as? Data { receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext["snapshot"] as? Data { receive(data) }
    }
    nonisolated private func receive(_ data: Data) {
        guard let value = try? JSONDecoder().decode(BriefingSnapshot.self, from: data) else { return }
        Task { @MainActor in self.snapshot = value; UserDefaults.standard.set(data, forKey: "watch.snapshot"); try? SharedSnapshot.write(value); WidgetCenter.shared.reloadAllTimelines() }
    }
}
@main @MainActor struct DailyBriefingWatchApp: App {
    @State private var store = WatchSnapshotStore()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    if let snapshot = store.snapshot {
                        Text("Saved \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        ForEach(snapshot.sections.filter { [.summary, .schedule, .weather, .tasks].contains($0.kind) }) { section in
                            Section(section.kind.title) {
                                if !section.isFresh(at: Date()) { Text("Cached · refresh on iPhone").font(.caption2).foregroundStyle(.orange) }
                                if section.items.isEmpty { Text(section.message).font(.caption) }
                                ForEach(Array(section.items.prefix(3))) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).font(.headline)
                                        if let date = item.date { Text(date, style: item.isShift && date > Date() ? .timer : .time).font(.caption) }
                                    }
                                }
                            }
                        }
                    } else { Text("Open Daily Briefing on your paired iPhone and refresh to send your briefing here.") }
                }.navigationTitle("Daily Briefing")
            }
        }
    }
}
