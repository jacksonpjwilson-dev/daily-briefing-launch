import Observation
import EventKit
import Foundation

@MainActor @Observable final class CalendarService {
    let store = EKEventStore()
    var calendars: [EKCalendar] = []
    var status = EKEventStore.authorizationStatus(for: .event)
    private var legacyEvents: [String: EKEvent] = [:]
    private var resolvedEvents: [String: EKEvent] = [:]
    var remindersStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    func request() async throws {
        _ = try await store.requestFullAccessToEvents()
        reload()
    }
    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        legacyEvents = [:]
        calendars = status == .fullAccess ? store.calendars(for: .event).sorted { $0.title < $1.title } : []
    }
    func events(preferences: AppPreferences, from start: Date, to end: Date) -> [BriefingItem] {
        reload()
        var items: [BriefingItem] = []
        resolvedEvents = [:]
        if status == .fullAccess {
            let selected = calendars.filter { preferences.calendarIDs.contains($0.calendarIdentifier) || $0.calendarIdentifier == preferences.workCalendarID }
            if !selected.isEmpty {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
                items = store.events(matching: predicate).map { event in
                    let occurrence: Date? = (event.hasRecurrenceRules || event.isDetached) ? event.occurrenceDate : nil
                    let id = CalendarIdentity.id(calendar: event.calendar.calendarIdentifier, item: event.calendarItemIdentifier, occurrence: occurrence)
                    resolvedEvents[id] = event
                    return BriefingItem(id: id,
                        title: event.title ?? "Calendar event", detail: [event.location, event.isAllDay ? "All day" : nil].compactMap { $0 }.joined(separator: " · "),
                        date: event.startDate, end: event.endDate, url: event.url, source: event.calendar.title,
                        isShift: preferences.scheduleSource == "calendar" && !event.isAllDay && event.calendar.calendarIdentifier == preferences.workCalendarID,
                        isAllDay: event.isAllDay, origin: .calendar, calendarIdentifier: event.calendar.calendarIdentifier, eventIdentifier: event.eventIdentifier)
                }
            }
        }
        return ManualSchedule.resolve(calendarItems: items, shifts: preferences.manualShifts, from: start, to: end, calendar: .autoupdatingCurrent)
    }
    func event(id: String) -> EKEvent? { resolvedEvents[id] }
    func reconcileLegacy(_ snapshot: BriefingSnapshot, preferences: AppPreferences) -> BriefingSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return snapshot }
        let selected = preferences.calendarIDs.union(preferences.workCalendarID.isEmpty ? [] : [preferences.workCalendarID])
        var value = snapshot
        for s in value.sections.indices where value.sections[s].kind == .schedule {
            for i in value.sections[s].items.indices {
                var item = value.sections[s].items[i]
                guard item.origin == nil, let separator = item.id.lastIndex(of: "@") else { continue }
                let eventID = String(item.id[..<separator])
                guard let event = legacyEvents[eventID] ?? store.event(withIdentifier: eventID), selected.contains(event.calendar.calendarIdentifier) else { continue }
                legacyEvents[eventID] = event
                let oldID = item.id
                item.origin = .calendar; item.calendarIdentifier = event.calendar.calendarIdentifier; item.eventIdentifier = event.eventIdentifier
                // A non-recurring record can be rekeyed without guessing an occurrence date.
                if !event.hasRecurrenceRules && !event.isDetached {
                    item.id = CalendarIdentity.id(calendar: event.calendar.calendarIdentifier, item: event.calendarItemIdentifier, occurrence: nil)
                    if value.pinnedItems.remove(oldID) != nil { value.pinnedItems.insert(item.id) }
                }
                value.sections[s].items[i] = item
            }
        }
        return value
    }
    func requestReminders() async throws { _ = try await store.requestFullAccessToReminders() }
    func reminders() async -> BriefingSection {
        do {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return BriefingSection(kind: .tasks, state: [.denied, .restricted].contains(remindersStatus) ? .permissionDenied : .disconnected, message: "Allow Reminders in Connections to include your tasks.")
            }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let fetch = ReminderFetch(store: store)
            let reminders = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { fetch.start(predicate: predicate, continuation: $0) }
            }, onCancel: { Task { @MainActor in fetch.cancel() } })
            let items = reminders.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }.prefix(50).map {
                BriefingItem(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder", detail: $0.priority > 0 ? "Priority \($0.priority)" : "", date: $0.dueDateComponents?.date, source: "Apple Reminders", origin: .reminder)
            }
            return BriefingSection(kind: .tasks, state: .ready, message: items.isEmpty ? "No outstanding reminders." : "", fetchedAt: Date(), expiresAt: Date().addingTimeInterval(900), items: items)
        } catch { return BriefingSection(kind: .tasks, state: .failed, message: error.localizedDescription) }
    }
}

@MainActor private final class ReminderFetch {
    private let store: EKEventStore
    private var continuation: CheckedContinuation<[EKReminder], Error>?
    private var token: Any?
    private var finished = false
    init(store: EKEventStore) { self.store = store }
    func start(predicate: NSPredicate, continuation: CheckedContinuation<[EKReminder], Error>) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        token = store.fetchReminders(matching: predicate) { [weak self] reminders in
            Task { @MainActor in self?.finish(reminders ?? []) }
        }
    }
    private func finish(_ reminders: [EKReminder]) {
        guard !finished else { return }; finished = true
        let continuation = continuation; self.continuation = nil; token = nil
        continuation?.resume(returning: reminders)
    }
    func cancel() {
        guard !finished else { return }; finished = true
        if let token { store.cancelFetchRequest(token) }
        token = nil
        let continuation = continuation; self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}
