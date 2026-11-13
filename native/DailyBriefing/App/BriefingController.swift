import Observation
import Foundation
import SwiftData
import EventKit
import CoreLocation
import WidgetKit

@MainActor @Observable final class BriefingController {
    let settings: SettingsStore
    let calendar = CalendarService()
    let location = LocationService()
    let speech = SpeechService()
    var snapshot: BriefingSnapshot?
    var now = Date()
    private var generation = GenerationStateMachine()
    var phase: GenerationPhase {
        if generation.phase == .loading || generation.phase == .failed { return generation.phase }
        return snapshot.map { [.partial, .interrupted].contains($0.status) ? .partial : .complete } ?? .idle
    }
    var errorMessage: String?
    var deliveryErrors: [String] = []
    var failedRefreshAttempts = UserDefaults.standard.integer(forKey: "failedRefreshAttempts")
    var route: SectionKind?
    private(set) var upcomingEvents: [BriefingItem] = []
    private let history: HistoryStore
    private var active: Task<Void, Never>?
    private var activeID: UUID?
    private var activeKinds: Set<SectionKind> = []
    private var queuedKinds: Set<SectionKind> = []
    private var replacementTask: Task<Void, Never>?
    private var replacementKinds: Set<SectionKind> = []
    private var lastPolicy: SnapshotAccessPolicy?

    init(settings: SettingsStore, container: ModelContainer) {
        self.settings = settings; history = HistoryStore(context: container.mainContext)
        var originals: [BriefingSnapshot] = []
        do {
            let saved = try history.load(); originals = saved
            snapshot = saved.last
            if !history.recoveryMessages.isEmpty { errorMessage = history.recoveryMessages.joined(separator: "\n") }
        } catch { errorMessage = "History could not be loaded; original data was preserved. \(error.localizedDescription)" }
        calendar.reload()
        upcomingEvents = queryEvents()
        settings.seedAnnotations(originals.map { calendar.reconcileLegacy($0, preferences: settings.value) })
        lastPolicy = accessPolicy
        location.setEnabled(accessPolicy.enabled.contains(.weather))
        if let snapshot { self.snapshot = visible(snapshot) }
        publishCurrent()
        settings.onChange = { [weak self] old, new in self?.settingsChanged(old: old, new: new) }
        _ = WatchBridge.shared
    }
    var accessPolicy: SnapshotAccessPolicy {
        let p = settings.value
        var ids = p.calendarIDs
        if !p.workCalendarID.isEmpty { ids.insert(p.workCalendarID) }
        var denied: Set<SectionKind> = []
        if [.denied, .restricted].contains(calendar.status) { denied.insert(.schedule) }
        if [.denied, .restricted].contains(calendar.remindersStatus) { denied.insert(.tasks) }
        if [.denied, .restricted].contains(location.status) { denied.insert(.weather) }
        return SnapshotAccessPolicy(enabled: settings.recoveryRequired ? [] : Set(p.sectionOrder).subtracting(p.hiddenSections),
            calendarAllowed: calendar.status == .fullAccess, remindersAllowed: calendar.remindersStatus == .fullAccess,
            locationAllowed: [.authorizedAlways, .authorizedWhenInUse].contains(location.status),
            calendarIDs: ids, manualIDs: Set(p.manualShifts.filter { $0.end > $0.start }.map { $0.id.uuidString }),
            aiAllowed: p.aiConsent, sourceVersions: settings.sourceVersions, deniedKinds: denied)
    }
    func visible(_ snapshot: BriefingSnapshot, historical: Bool = false) -> BriefingSnapshot {
        let policy = accessPolicy
        let original = historical && policy.enabled.contains(.schedule) && policy.calendarAllowed
            ? calendar.reconcileLegacy(snapshot, preferences: settings.value) : snapshot
        return policy.applying(to: settings.annotations.applying(to: original), historical: historical)
    }
    var needsRefresh: Bool {
        guard !settings.recoveryRequired, !accessPolicy.enabled.isEmpty else { return false }
        guard let snapshot else { return true }
        let target = BriefingScheduler.target(at: now, events: upcomingEvents, preferences: settings.value.scheduling, calendar: .autoupdatingCurrent)
        return !accessPolicy.enabled.isSubset(of: Set(snapshot.sections.map(\.kind))) || accessPolicy.enabled.contains(where: { snapshot.sourceVersions[$0.rawValue] != settings.sourceVersions[$0.rawValue] }) || snapshot.target != target || [.refreshing, .interrupted].contains(snapshot.status) ||
            now.timeIntervalSince(snapshot.updatedAt ?? snapshot.generatedAt) > 900
    }
    private func queryEvents() -> [BriefingItem] {
        let c = Calendar.autoupdatingCurrent
        return calendar.events(preferences: settings.value, from: c.startOfDay(for: now), to: c.date(byAdding: .day, value: 9, to: now)!)
    }
    func revalidateAccess() {
        calendar.reload(); location.reloadAuthorization()
        let current = accessPolicy
        var changed: Set<SectionKind> = []
        if let prior = lastPolicy {
            if prior.calendarAllowed != current.calendarAllowed { changed.insert(.schedule) }
            if prior.remindersAllowed != current.remindersAllowed { changed.insert(.tasks) }
            if prior.locationAllowed != current.locationAllowed { changed.insert(.weather) }
        }
        if !changed.isEmpty {
            active?.cancel(); speech.stop(); settings.invalidate(changed)
            if changed.contains(.schedule) { Task { await ShiftActivities.endAll() } }
            if let snapshot { self.snapshot = visible(snapshot) }
            publishCurrent()
        }
        lastPolicy = accessPolicy
        location.setEnabled(accessPolicy.enabled.contains(.weather))
        if settings.recoveryRequired { errorMessage = settings.recoveryNotice }
    }
    func sourceUpdated(_ kinds: Set<SectionKind>) async {
        let replacement = activeKinds.union(kinds).union([.summary])
        active?.cancel(); speech.stop(); settings.invalidate(kinds)
        if let snapshot { self.snapshot = visible(snapshot) }
        publishCurrent()
        await refresh(kinds: replacement)
    }
    func tick() async {
        now = Date(); revalidateAccess()
        if needsRefresh { await refresh() }
    }
    private func settingsChanged(old: AppPreferences, new: AppPreferences) {
        let changed = AppPreferences.changedSources(from: old, to: new)
        replacementKinds.formUnion(activeKinds.union(changed))
        if old == new && lastPolicy?.enabled != accessPolicy.enabled { replacementKinds.formUnion(accessPolicy.enabled) }
        if !settings.annotationsSeeded {
            do { settings.seedAnnotations(try history.load(recoverInterrupted: false).map { calendar.reconcileLegacy($0, preferences: settings.value) }) }
            catch { errorMessage = error.localizedDescription }
        }
        if !changed.isEmpty || settings.recoveryRequired { active?.cancel(); speech.stop() }
        if changed.contains(.schedule) { Task { await ShiftActivities.endAll() } }
        if let snapshot { self.snapshot = visible(snapshot) }
        lastPolicy = accessPolicy
        location.setEnabled(accessPolicy.enabled.contains(.weather))
        // Commit the new privacy gate before any asynchronous work or network request.
        publishCurrent()
        replacementTask?.cancel()
        let needsScheduling = old.notificationsEnabled != new.notificationsEnabled || old.notificationPolicy != new.notificationPolicy || old.scheduling != new.scheduling
        replacementTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let requested = replacementKinds; replacementKinds = []
            if !requested.isEmpty { await refresh(kinds: requested) }
            else if needsScheduling { await reschedule() }
        }
    }
    func refresh(only kind: SectionKind? = nil, background: Bool = false) async {
        await refresh(kinds: kind.map { [$0] }, background: background)
    }
    func refresh(kinds requested: Set<SectionKind>?, background: Bool = false) async {
        while let task = active {
            if task.isCancelled {
                let id = activeID; await task.value
                if activeID == id { active = nil; activeID = nil }
                continue
            }
            queuedKinds.formUnion((requested ?? accessPolicy.enabled).subtracting(activeKinds))
            await task.value
            return
        }
        now = Date(); revalidateAccess()
        guard !settings.recoveryRequired else {
            errorMessage = settings.recoveryNotice; publishCurrent(); await reschedule(); return
        }
        let id = UUID()
        let initial = (requested ?? accessPolicy.enabled).intersection(accessPolicy.enabled)
        // A source change may invalidate the summary even when it was not explicitly requested.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var kinds = initial
            repeat {
                activeKinds = kinds
                await performRefresh(kinds: kinds, background: background)
                if Task.isCancelled { break }
                kinds = queuedKinds.intersection(accessPolicy.enabled); queuedKinds = []
            } while !kinds.isEmpty
        }
        active = task; activeID = id
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if activeID == id { active = nil; activeID = nil; queuedKinds = []; activeKinds = [] }
    }
    private func performRefresh(kinds: Set<SectionKind>, background: Bool) async {
        guard generation.start() else { return }
        now = Date()
        errorMessage = history.recoveryMessages.isEmpty ? nil : history.recoveryMessages.joined(separator: "\n")
        let p = settings.value, policy = accessPolicy, versions = settings.sourceVersions
        upcomingEvents = queryEvents()
        let target = BriefingScheduler.target(at: now, events: upcomingEvents, preferences: p.scheduling, calendar: .autoupdatingCurrent)
        let previous = snapshot
        var candidate = BriefingSnapshot(generatedAt: now, sections: previous?.sections ?? [], nextDelivery: nil)
        candidate.target = target; candidate.sourceVersions = previous?.sourceVersions ?? [:]
        candidate.status = .refreshing; candidate.updatedAt = now
        if previous?.target != target { candidate.sections.removeAll { $0.kind == .schedule || $0.kind == .summary } }
        candidate = policy.applying(to: candidate)
        let enabled = kinds.intersection(policy.enabled)
        if !enabled.isEmpty, !enabled.isSubset(of: [.summary]) {
            if let i = candidate.sections.firstIndex(where: { $0.kind == .summary }) {
                candidate.sections[i].state = .stale; candidate.sections[i].items = []
                candidate.sections[i].message = "Sources changed. Regenerate the summary."
            }
        }
        // Resubmit before starting providers; expiration/failure must not break the refresh chain.
        await reschedule()
        do { try checkpoint(candidate) }
        catch { failStorage(error); await reschedule(); return }
        let clock = ContinuousClock()
        let began = clock.now
        let totalBudget = background ? 24.0 : 32.0
        let sourcesBudget = background ? 16.0 : 22.0
        let locationValue = location.location
        let schedule = scheduleSection(target: target, preferences: p)
        let jobs = enabled.filter { $0 != .summary }.map { kind -> RefreshJob in
            RefreshJob(kind: kind, timeout: sourcesBudget) { [calendar] in
                try Task.checkCancellation()
                switch kind {
                case .schedule: return schedule
                case .tasks: return await calendar.reminders()
                case .weather: return try await WeatherProvider().fetch(location: locationValue, fahrenheit: p.fahrenheit, targetDay: target.dayStart)
                case .news: return try await NewsProvider().fetch(preferences: p)
                case .aviation: return try await AviationProvider().fetch(preferences: p)
                case .email: return BriefingSection(kind: .email, state: .disconnected, message: "No email provider connected. Gmail OAuth requires a registered client and secure token exchange service.")
                case .sports: return BriefingSection(kind: .sports, state: .disconnected, message: "Teams: \(p.teams). Connect a legitimate sports provider to show verified scores and games.")
                case .summary: return BriefingSection(kind: .summary, state: .missingData)
                }
            }
        }
        var completion = await RefreshCoordinator.run(jobs: jobs, enabled: policy.enabled, budget: sourcesBudget, reschedule: { [self] in await reschedule() }) { [self] result in
            guard settings.sourceVersions == versions, !Task.isCancelled else { return }
            var section = result
            if [.failed, .offline, .timedOut].contains(section.state), let cached = previous?.sections.first(where: { $0.kind == section.kind }),
               previous?.sourceVersions[section.kind.rawValue] == versions[section.kind.rawValue] {
                section.items = cached.items; section.fetchedAt = cached.fetchedAt; section.expiresAt = cached.expiresAt
                if !section.items.isEmpty { section.message += " Showing last saved information; it may be outdated." }
            }
            candidate.sections.removeAll { $0.kind == section.kind }; candidate.sections.append(section)
            candidate.sourceVersions[section.kind.rawValue] = versions[section.kind.rawValue]
            candidate.updatedAt = Date()
            try checkpoint(candidate)
        }
        if completion == .persistenceFailed { generation.fail(); errorMessage = "Refresh paused because a checkpoint could not be saved. Earlier checkpoints are preserved." }
        // Never run a disabled summary, nor upload inputs after cancellation or a policy change.
        if completion == .complete, !Task.isCancelled, versions == settings.sourceVersions,
           enabled.contains(.summary), policy.enabled.contains(.summary) {
            let elapsed = began.duration(to: clock.now).components
            let remaining = totalBudget - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            let inputs = policy.applying(to: candidate).sections.filter { $0.kind != .summary && $0.isFresh(at: Date()) }.map { section in
                var section = section; section.items.removeAll { $0.sourceExpiresAt.map { $0 <= Date() } == true }; return section
            }
            let summaryJob = RefreshJob(kind: .summary, timeout: max(0.01, remaining)) {
                if p.aiConsent, let endpoint = URL(string: p.aiEndpoint), !p.aiEndpoint.isEmpty {
                    return try await HTTPSummaryProvider(endpoint: endpoint).summarize(sections: inputs, length: p.summaryLength)
                }
                return BriefingSection(kind: .summary, state: .ready, message: "Source roll-up · AI is off.", fetchedAt: Date(), expiresAt: inputs.compactMap(\.expiresAt).min() ?? Date().addingTimeInterval(900),
                    items: inputs.flatMap { section in section.items.prefix(2).map { item in
                        BriefingItem(id: "rollup.\(item.id)", title: item.title, detail: item.detail, date: item.date, url: item.url, source: section.kind.title + " · " + item.source)
                    } }, dependencies: Set(inputs.map(\.kind)))
            }
            completion = await RefreshCoordinator.run(jobs: [summaryJob], enabled: accessPolicy.enabled, budget: max(0.01, remaining), reschedule: { [self] in await reschedule() }) { [self] result in
                guard settings.sourceVersions == versions, !Task.isCancelled else { return }
                var summary = result; summary.dependencies = Set(inputs.map(\.kind))
                for i in summary.items.indices where summary.isGenerated { summary.items[i].id = "summary." + target.dayKey }
                candidate.sections.removeAll { $0.kind == .summary }; candidate.sections.append(summary)
                candidate.sourceVersions[SectionKind.summary.rawValue] = versions[SectionKind.summary.rawValue]
                try checkpoint(candidate)
            }
        }
        if Task.isCancelled || settings.sourceVersions != versions || completion == .interrupted { candidate.status = .interrupted }
        else { candidate.status = candidate.sections.allSatisfy { $0.state == .ready } ? .complete : .partial }
        candidate.changes = BriefingChanges.compare(previous, candidate); candidate.updatedAt = Date()
        do { try checkpoint(candidate) }
        catch { failStorage(error) }
        if completion != .persistenceFailed && generation.phase != .failed {
            if candidate.sections.isEmpty { generation.cancel() } else { generation.finish(sections: candidate.sections) }
        }
        if completion == .persistenceFailed || candidate.sections.contains(where: { [.failed, .timedOut, .offline].contains($0.state) }) {
            failedRefreshAttempts += 1; UserDefaults.standard.set(failedRefreshAttempts, forKey: "failedRefreshAttempts")
        }
        if candidate.status != .interrupted && completion == .complete { UserDefaults.standard.set(Date(), forKey: "lastCompletedGeneration") }
        do { try history.prune(before: Calendar.current.date(byAdding: .day, value: -p.retentionDays, to: Date())!) }
        catch { errorMessage = "Briefing saved, but history cleanup needs attention. \(error.localizedDescription)" }
        await reschedule()
        await ShiftActivities.endExpired()
    }
    private func scheduleSection(target: BriefingTarget, preferences p: AppPreferences) -> BriefingSection {
        let items = upcomingEvents.filter(target.contains)
        let available = Set(calendar.calendars.map(\.calendarIdentifier))
        let connected = calendar.status == .fullAccess && (!p.calendarIDs.intersection(available).isEmpty || available.contains(p.workCalendarID))
        let denied = (!p.calendarIDs.isEmpty || !p.workCalendarID.isEmpty) && [.denied, .restricted].contains(calendar.status)
        return BriefingSection(kind: .schedule, state: connected || !items.isEmpty ? .ready : denied ? .permissionDenied : .disconnected,
            message: denied ? "Calendar access unavailable. Manual entries remain available." : !connected && items.isEmpty ? "Select available calendars or add a manual shift in Settings." : items.isEmpty ? "No commitments on this briefing date." : "",
            fetchedAt: Date(), expiresAt: Date().addingTimeInterval(900), items: items)
    }
    private func checkpoint(_ value: BriefingSnapshot) throws {
        var next = settings.annotations.applying(to: accessPolicy.applying(to: value))
        next.sections.sort { (settings.value.sectionOrder.firstIndex(of: $0.kind) ?? 99) < (settings.value.sectionOrder.firstIndex(of: $1.kind) ?? 99) }
        next.nextDelivery = deliveries().first
        try history.save(next)
        snapshot = next; publishCurrent()
    }
    private func failStorage(_ error: Error) { generation.fail(); errorMessage = "Unable to save the current checkpoint. Earlier saved data is preserved. \(error.localizedDescription)" }
    private func deliveries() -> [Date] {
        BriefingScheduler.upcoming(after: Date(), shifts: upcomingEvents.filter(\.isShift).compactMap(\.date), preferences: settings.value.scheduling, calendar: .autoupdatingCurrent)
    }
    private func reschedule() async {
        if accessPolicy.enabled.isEmpty || settings.recoveryRequired {
            BackgroundRefresh.cancel()
        } else { do { try BackgroundRefresh.schedule(at: deliveries().first) }
            catch { addDeliveryError("Background refresh unavailable; open the app to refresh.") }
        }
        var preferences = settings.value
        if accessPolicy.enabled.isEmpty || settings.recoveryRequired { preferences.notificationsEnabled = false }
        do { try await NotificationService.schedule(dates: deliveries(), preferences: preferences) }
        catch { addDeliveryError("Notification scheduling failed: \(error.localizedDescription)") }
    }
    private func addDeliveryError(_ message: String) { if !deliveryErrors.contains(message) { deliveryErrors.append(message) } }
    private func publishCurrent() {
        let policy = accessPolicy
        let current = snapshot.map { visible($0) } ?? BriefingSnapshot(generatedAt: Date(), sections: [], nextDelivery: nil)
        SharedSnapshot.selectedSection = policy.enabled.contains(settings.value.widgetSection) ? settings.value.widgetSection : policy.enabled.sorted { $0.rawValue < $1.rawValue }.first ?? .schedule
        do { try SharedSnapshot.write(current, policy: policy) }
        catch { addDeliveryError("Widget cache unavailable. Check App Group signing.") }
        WidgetCenter.shared.reloadAllTimelines()
        do { try WatchBridge.shared.publish(current, policy: policy) }
        catch { addDeliveryError("Watch transfer failed; the latest privacy-filtered snapshot will be retried.") }
    }
    func update(_ incoming: BriefingSnapshot) {
        settings.recordAnnotations(incoming)
        do {
            let saved = try history.load(recoverInterrupted: false)
            if let original = saved.first(where: { $0.id == incoming.id }) { try history.save(settings.annotations.applying(to: original)) }
            if let snapshot { self.snapshot = visible(snapshot) }
            publishCurrent()
        } catch { errorMessage = error.localizedDescription }
    }
    func restore(_ row: SavedBriefing) {
        do { try history.restore(row); errorMessage = "Restored the readable backup. Current privacy settings still apply." }
        catch { errorMessage = error.localizedDescription }
    }
    var healthReport: HealthReport {
        HealthReport(lastSuccessfulGeneration: UserDefaults.standard.object(forKey: "lastCompletedGeneration") as? Date,
            nextScheduledBriefing: snapshot?.nextDelivery,
            providers: (snapshot?.sections ?? []).map { .init(section: $0.kind, state: $0.assessed(at: now).state, lastRefresh: $0.fetchedAt) },
            integrationErrors: errorMessage.map { [$0] } ?? [], deliveryErrors: deliveryErrors, failedRefreshAttempts: failedRefreshAttempts,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }
}
