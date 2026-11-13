import Observation
import EventKit
import Foundation

@MainActor @Observable final class CalendarService {
    let store = EKEventStore()
    var calendars: [EKCalendar] = []
    var status = EKEventStore.authorizationStatus(for: .event)
    private var resolvedEvents: [String: EKEvent] = [:]
    var remindersStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }
    func request() async throws {
        _ = try await store.requestFullAccessToEvents()
        reload()
    }
    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
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
                        date: event.startDate, end: event.endDate, source: event.calendar.title,
                        isShift: preferences.scheduleSource == "calendar" && !event.isAllDay && event.calendar.calendarIdentifier == preferences.workCalendarID,
                        isAllDay: event.isAllDay, origin: .calendar, calendarIdentifier: event.calendar.calendarIdentifier, eventIdentifier: event.eventIdentifier)
                }
            }
        }
        return ManualSchedule.resolve(calendarItems: items, shifts: preferences.manualShifts, from: start, to: end, calendar: .autoupdatingCurrent)
    }
    func event(id: String) -> EKEvent? { resolvedEvents[id] }
    func requestReminders() async throws { _ = try await store.requestFullAccessToReminders() }
    func reminders() async -> BriefingSection {
        do {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return BriefingSection(kind: .tasks, state: [.denied, .restricted].contains(remindersStatus) ? .permissionDenied : .disconnected, message: "Allow Reminders in Connections to include your tasks.")
            }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            let items = reminders.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }.prefix(50).map {
                BriefingItem(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder", detail: $0.priority > 0 ? "Priority \($0.priority)" : "", date: $0.dueDateComponents?.date, source: "Apple Reminders", origin: .reminder)
            }
            return BriefingSection(kind: .tasks, state: .ready, message: items.isEmpty ? "No outstanding reminders." : "", fetchedAt: Date(), expiresAt: Date().addingTimeInterval(900), items: items)
        } catch { return BriefingSection(kind: .tasks, state: .failed, message: error.localizedDescription) }
    }
}
