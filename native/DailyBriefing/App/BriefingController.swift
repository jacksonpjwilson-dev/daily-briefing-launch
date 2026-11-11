import Foundation
import SwiftData
import WidgetKit

@MainActor @Observable final class BriefingController {
    let settings: SettingsStore
    let calendar = CalendarService()
    let location = LocationService()
    let speech = SpeechService()
    var snapshot: BriefingSnapshot?
    var phase = GenerationPhase.idle
    var errorMessage: String?
    var deliveryErrors: [String] = []
    var failedRefreshAttempts = 0
    var route: SectionKind?
    private(set) var upcomingEvents: [BriefingItem] = []
    private let context: ModelContext
    init(settings: SettingsStore, container: ModelContainer) {
        self.settings = settings; context = ModelContext(container)
        var query = FetchDescriptor<SavedBriefing>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        query.fetchLimit = 1
        snapshot = (try? context.fetch(query))?.first?.snapshot
        calendar.reload()
        _ = WatchBridge.shared
    }
    func refresh(only kind: SectionKind? = nil) async {
        guard phase != .loading else { return }
        phase = .loading; errorMessage = nil
        let now = Date(), p = settings.value, c = Calendar.autoupdatingCurrent
        let start = c.startOfDay(for: now)
        let end = c.date(byAdding: .day, value: 9, to: start)!
        upcomingEvents = calendar.events(preferences: p, from: start, to: end)
        let shifts = upcomingEvents.filter(\.isShift).compactMap(\.date)
        let deliveries = BriefingScheduler.upcoming(after: now, shifts: shifts, preferences: p.scheduling, calendar: c)
        var sections: [BriefingSection] = kind == nil ? [] : (snapshot?.sections ?? []).filter { !p.hiddenSections.contains($0.kind) }
        let selected = kind.map { [$0] } ?? p.sectionOrder.filter { !p.hiddenSections.contains($0) }
        for section in selected where section != .summary {
            if Task.isCancelled { phase = .idle; return }
            var result: BriefingSection
            do {
                switch section {
                case .schedule:
                    let todayEnd = c.date(byAdding: .day, value: 1, to: start)!
                    let items = upcomingEvents.filter { ($0.date ?? .distantFuture) < todayEnd && ($0.end ?? .distantPast) > start }
                    let hasCalendar = calendar.status == .fullAccess && (!p.calendarIDs.isEmpty || !p.workCalendarID.isEmpty)
                    result = BriefingSection(kind: .schedule, state: hasCalendar || !p.manualShifts.isEmpty ? .ready : .disconnected,
                        message: !hasCalendar && p.manualShifts.isEmpty ? "Select calendars or add a manual shift in Settings." : items.isEmpty ? "No commitments today." : "",
                        fetchedAt: now, expiresAt: now.addingTimeInterval(900), items: items)
                case .tasks: result = await calendar.reminders()
                case .weather: result = try await WeatherProvider().fetch(location: location.location, fahrenheit: p.fahrenheit)
                case .aviation: result = try await AviationProvider().fetch(preferences: p)
                case .news: result = try await NewsProvider().fetch(preferences: p)
                case .email: result = BriefingSection(kind: .email, state: .disconnected, message: "No email provider connected. Gmail OAuth requires a registered client and secure token exchange service.")
                case .sports: result = BriefingSection(kind: .sports, state: .disconnected, message: "Teams: \(p.teams). Connect a licensed sports provider to show verified scores and games.")
                case .summary: continue
                }
            } catch { result = HTTP.failed(section, error: error) }
            if [.failed, .offline].contains(result.state), let cached = snapshot?.sections.first(where: { $0.kind == section }), !cached.items.isEmpty {
                result.items = cached.items; result.fetchedAt = cached.fetchedAt; result.expiresAt = cached.expiresAt
                result.message += " Showing last saved information; it may be outdated."
            }
            sections.removeAll { $0.kind == section }; sections.append(result)
        }
        if selected.contains(.summary) || kind == nil {
            var summary: BriefingSection
            if p.aiConsent, let endpoint = URL(string: p.aiEndpoint), !p.aiEndpoint.isEmpty {
                do { summary = try await HTTPSummaryProvider(endpoint: endpoint).summarize(sections: sections, length: p.summaryLength) }
                catch { summary = HTTP.failed(.summary, error: error) }
            } else {
                let verified = sections.filter { $0.kind != .summary && $0.isFresh(at: now) }
                let conflicts = BriefingScheduler.conflicts(sections.first { $0.kind == .schedule }?.items ?? [])
                summary = BriefingSection(kind: .summary, state: .ready,
                    message: "Source roll-up · AI is off. \(conflicts.isEmpty ? "" : "Overlapping commitments need attention.")",
                    fetchedAt: now, expiresAt: now.addingTimeInterval(900),
                    items: verified.flatMap { section in section.items.prefix(2).map { item in
                        BriefingItem(id: "rollup.\(item.id)", title: item.title, detail: item.detail, date: item.date, url: item.url, source: section.kind.title + " · " + item.source)
                    } })
            }
            sections.removeAll { $0.kind == .summary }; sections.append(summary)
        } else if kind != .summary {
            // Any source change invalidates an older AI interpretation.
            sections = sections.map { section in
                guard section.kind == .summary else { return section }
                var stale = section; stale.state = .stale; stale.message = "Sources changed. Regenerate the summary."; return stale
            }
        }
        sections.sort { (p.sectionOrder.firstIndex(of: $0.kind) ?? 99) < (p.sectionOrder.firstIndex(of: $1.kind) ?? 99) }
        var next = BriefingSnapshot(generatedAt: now, sections: sections, nextDelivery: deliveries.first)
        if let previous = snapshot {
            next.changes = sections.filter { $0.kind != .summary }.compactMap { section in
                guard let old = previous.sections.first(where: { $0.kind == section.kind }) else { return "Added \(section.kind.title)." }
                if old.state != section.state { return "\(section.kind.title): \(old.state.rawValue) → \(section.state.rawValue)." }
                let before = old.items.map { $0.title + $0.detail }
                let after = section.items.map { $0.title + $0.detail }
                return before == after ? nil : "\(section.kind.title) has updated information."
            }
        }
        do {
            context.insert(try SavedBriefing(next)); try context.save()
            snapshot = next; phase = .result(for: sections)
            failedRefreshAttempts += sections.filter { [.failed, .offline].contains($0.state) }.count
            let cutoff = c.date(byAdding: .day, value: -p.retentionDays, to: now)!
            let old = try context.fetch(FetchDescriptor<SavedBriefing>(predicate: #Predicate { $0.generatedAt < cutoff }))
            for row in old { context.delete(row) }; try context.save()
        } catch { phase = .failed; failedRefreshAttempts += 1; errorMessage = "Unable to save briefing: \(error.localizedDescription)"; return }
        deliveryErrors = []
        SharedSnapshot.selectedSection = p.widgetSection
        do { try SharedSnapshot.write(next); WidgetCenter.shared.reloadAllTimelines() }
        catch { deliveryErrors.append("Widget cache unavailable. Check App Group signing.") }
        do { try WatchBridge.shared.publish(next) } catch { deliveryErrors.append("Watch transfer failed.") }
        do { try await NotificationService.schedule(dates: deliveries, preferences: p) } catch { deliveryErrors.append("Notification scheduling failed: \(error.localizedDescription)") }
        do { try BackgroundRefresh.schedule(at: deliveries.first) } catch { deliveryErrors.append("Background refresh unavailable; open the app to refresh.") }
        await ShiftActivities.endExpired()
    }
    func update(_ snapshot: BriefingSnapshot) {
        do {
            let id = snapshot.id
            if let row = try context.fetch(FetchDescriptor<SavedBriefing>(predicate: #Predicate { $0.id == id })).first {
                row.payload = try JSONEncoder().encode(snapshot); row.text = snapshot.summaryText; try context.save()
            }
            if self.snapshot?.id == snapshot.id { self.snapshot = snapshot }
        } catch { errorMessage = error.localizedDescription }
    }
    var healthReport: HealthReport {
        HealthReport(lastSuccessfulGeneration: snapshot?.generatedAt, nextScheduledBriefing: snapshot?.nextDelivery,
            providers: (snapshot?.sections ?? []).map { .init(section: $0.kind, state: $0.assessed(at: Date()).state, lastRefresh: $0.fetchedAt) },
            integrationErrors: errorMessage.map { [$0] } ?? [], deliveryErrors: deliveryErrors,
            failedRefreshAttempts: failedRefreshAttempts,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }
}
